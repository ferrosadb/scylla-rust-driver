# Time

Depending on feature flags used, three different types can be used to interact with time.

Internally [time](https://docs.scylladb.com/stable/cql/types.html#times) is represented as number of nanoseconds since
midnight. It can't be negative or exceed `86399999999999` (23:59:59.999999999).

## CqlTime

Without any extra features enabled, only `value::CqlTime` is available. It's an
[`i64`](https://doc.rust-lang.org/std/primitive.i64.html) wrapper and it matches the internal time representation.

However, for most use cases other types are more practical. See the following section for `time`.

```rust
# extern crate scylla;
# extern crate futures;
# use scylla::client::session::Session;
# use std::error::Error;
# async fn check_only_compiles(session: &Session) -> Result<(), Box<dyn Error>> {
use scylla::value::CqlTime;
use futures::TryStreamExt;

// 64 seconds since midnight
let to_insert = CqlTime(64 * 1_000_000_000);

// Insert time into the table
session
    .query_unpaged("INSERT INTO keyspace.table (a) VALUES(?)", (to_insert,))
    .await?;

// Read time from the table
let mut iter = session.query_iter("SELECT a FROM keyspace.table", &[])
    .await?
    .rows_stream::<(CqlTime,)>()?;
while let Some((value,)) = iter.try_next().await? {
    // ...
}
# Ok(())
# }
```

## time::Time

If the `time-03` feature is enabled, [`time::Time`](https://docs.rs/time/0.3/time/struct.Time.html) can be used to interact
with the database.

```rust
# extern crate scylla;
# extern crate time;
# extern crate futures;
# use scylla::client::session::Session;
# use std::error::Error;
# async fn check_only_compiles(session: &Session) -> Result<(), Box<dyn Error>> {
use futures::TryStreamExt;
use time::Time;

// 01:02:03.456,789,012
let to_insert = Time::from_hms_nano(1, 2, 3, 456_789_012).unwrap();

// Insert time into the table
session
    .query_unpaged("INSERT INTO keyspace.table (a) VALUES(?)", (to_insert,))
    .await?;

// Read time from the table
let mut iter = session.query_iter("SELECT a FROM keyspace.table", &[])
    .await?
    .rows_stream::<(Time,)>()?;
while let Some((time_value,)) = iter.try_next().await? {
    println!("{:?}", time_value);
}
# Ok(())
# }
```
