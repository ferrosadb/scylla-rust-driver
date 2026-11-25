//! Paths the ferrosa products depend on, checked against a real server.
//!
//! Upstream's suite targets Scylla. These tests cover what ferrosa-memory and
//! the installer use that no upstream test reaches against a Cassandra-style
//! server: CEP-30 `vector<float, N>` columns carried as raw big-endian bytes
//! (the fork's VectorType fix), and multi-page reads through both the pager
//! and manual paging state. They use only standard CQL, so they also pass on
//! Cassandra 5.

use crate::utils::{create_new_session_builder, setup_tracing, unique_keyspace_name, PerformDDL};
use futures::TryStreamExt;
use scylla::frame::response::result::CqlValue;
use scylla::query::Query;
use scylla::statement::{PagingState, PagingStateResponse};
use scylla::Session;

const DIM: usize = 4;
const ROWS: i32 = 25;
const PAGE_SIZE: i32 = 7;

async fn session_in_fresh_keyspace() -> (Session, String) {
    setup_tracing();
    let session = create_new_session_builder().build().await.unwrap();
    let ks = unique_keyspace_name();
    session
        .ddl(format!(
            "CREATE KEYSPACE {ks} WITH REPLICATION = \
             {{'class': 'SimpleStrategy', 'replication_factor': 1}}"
        ))
        .await
        .unwrap();
    session.use_keyspace(&ks, false).await.unwrap();
    (session, ks)
}

/// The layout ferrosa-memory's `encode_vector` writes: big-endian f32s, no
/// per-element length prefix.
fn encode_f32_be(values: &[f32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_be_bytes()).collect()
}

#[tokio::test]
async fn vector_float_column_round_trips_raw_bytes() {
    let (session, _ks) = session_in_fresh_keyspace().await;
    session
        .ddl(format!(
            "CREATE TABLE emb (id int PRIMARY KEY, v vector<float, {DIM}>)"
        ))
        .await
        .unwrap();

    let values = [1.5_f32, -2.25, 0.0, 1e-3];
    let bytes = encode_f32_be(&values);
    assert_eq!(bytes.len(), DIM * 4);

    let insert = session
        .prepare("INSERT INTO emb (id, v) VALUES (?, ?)")
        .await
        .unwrap();
    session
        .execute_unpaged(&insert, (1_i32, &bytes))
        .await
        .unwrap();

    // Typed path: a prepared SELECT reads the column back into Vec<u8>.
    let select = session
        .prepare("SELECT v FROM emb WHERE id = ?")
        .await
        .unwrap();
    let (read,): (Vec<u8>,) = session
        .execute_unpaged(&select, (1_i32,))
        .await
        .unwrap()
        .into_rows_result()
        .unwrap()
        .single_row::<(Vec<u8>,)>()
        .unwrap();
    assert_eq!(read, bytes, "vector bytes changed on the round trip");

    // Untyped path: the server's VectorType decodes into a list of floats.
    let (cql,): (CqlValue,) = session
        .query_unpaged("SELECT v FROM emb WHERE id = 1", ())
        .await
        .unwrap()
        .into_rows_result()
        .unwrap()
        .single_row::<(CqlValue,)>()
        .unwrap();
    let expected = CqlValue::List(values.iter().map(|f| CqlValue::Float(*f)).collect());
    assert_eq!(cql, expected);
}

async fn table_with_one_wide_partition(session: &Session) {
    session
        .ddl("CREATE TABLE wide (p int, c int, v text, PRIMARY KEY (p, c))")
        .await
        .unwrap();
    let insert = session
        .prepare("INSERT INTO wide (p, c, v) VALUES (0, ?, ?)")
        .await
        .unwrap();
    for c in 0..ROWS {
        session
            .execute_unpaged(&insert, (c, format!("row-{c}")))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn pager_reads_every_row_across_pages() {
    let (session, _ks) = session_in_fresh_keyspace().await;
    table_with_one_wide_partition(&session).await;

    let mut select = session
        .prepare("SELECT c, v FROM wide WHERE p = 0")
        .await
        .unwrap();
    select.set_page_size(PAGE_SIZE);
    let rows: Vec<(i32, String)> = session
        .execute_iter(select, ())
        .await
        .unwrap()
        .rows_stream::<(i32, String)>()
        .unwrap()
        .try_collect()
        .await
        .unwrap();

    let expected: Vec<(i32, String)> = (0..ROWS).map(|c| (c, format!("row-{c}"))).collect();
    assert_eq!(rows, expected);
}

#[tokio::test]
async fn manual_paging_state_walks_every_page() {
    let (session, _ks) = session_in_fresh_keyspace().await;
    table_with_one_wide_partition(&session).await;

    let query = Query::new("SELECT c FROM wide WHERE p = 0").with_page_size(PAGE_SIZE);
    let prepared = session.prepare(query).await.unwrap();

    let mut seen = Vec::new();
    let mut pages = 0;
    let mut state = PagingState::start();
    // Bounded: ROWS / PAGE_SIZE pages plus slack for a trailing empty page.
    let max_pages = (ROWS / PAGE_SIZE) as usize + 3;
    loop {
        assert!(
            pages < max_pages,
            "paging did not terminate after {pages} pages"
        );
        let (result, response) = session
            .execute_single_page(&prepared, (), state)
            .await
            .unwrap();
        let page: Vec<i32> = result
            .into_rows_result()
            .unwrap()
            .rows::<(i32,)>()
            .unwrap()
            .map(|r| r.map(|(c,)| c))
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            page.len() <= PAGE_SIZE as usize,
            "page of {} rows exceeds page size {PAGE_SIZE}",
            page.len()
        );
        seen.extend(page);
        pages += 1;
        match response {
            PagingStateResponse::HasMorePages { state: next } => state = next,
            PagingStateResponse::NoMorePages => break,
        }
    }

    assert!(pages > 1, "expected several pages, got {pages}");
    assert_eq!(seen, (0..ROWS).collect::<Vec<_>>());
}
