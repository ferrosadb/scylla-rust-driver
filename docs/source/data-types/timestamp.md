# Timestamp

Depending on feature flags, three different types can be used to interact with timestamps.

Internally [timestamp](https://docs.scylladb.com/stable/cql/types.html#timestamps) is represented as
[`i64`](https://doc.rust-lang.org/std/primitive.i64.html) describing number of milliseconds since unix epoch.

## CqlTimestamp

Without any extra features enabled, only `value::CqlTimestamp` is available. It's an
[`i64`](https://doc.rust-lang.org/std/primitive.i64.html) wrapper and it matches the internal time representation. It's
the only type that supports full range of values that database accepts.

However, for most use cases other types are more practical. See the following section for `time`.

```rust
# extern crate scylla;
# extern crate futures;
# use scylla::client::session::Session;
# use std::error::Error;
# async fn check_only_compiles(session: &Session) -> Result<(), Box<dyn Error>> {
use scylla::value::CqlTimestamp;
use futures::TryStreamExt;

// 64 seconds since unix epoch, 1970-01-01 00:01:04
let to_insert = CqlTimestamp(64 * 1000);

// Write timestamp to the table
session
    .query_unpaged("INSERT INTO keyspace.table (a) VALUES(?)", (to_insert,))
    .await?;

// Read timestamp from the table
let mut iter = session.query_iter("SELECT a FROM keyspace.table", &[])
    .await?
    .rows_stream::<(CqlTimestamp,)>()?;
while let Some((value,)) = iter.try_next().await? {
    // ...
}
# Ok(())
# }
```

## time::OffsetDateTime

Alternatively, the `time-03` feature can be used to enable support of
[`time::OffsetDateTime`](https://docs.rs/time/0.3/time/struct.OffsetDateTime.html). As
[timestamp](https://docs.scylladb.com/stable/cql/types.html#timestamps) doesn't support timezone information, time will
be corrected to UTC and timezone info will be erased on write. On read, UTC timestamp is returned. Any precision finer
than 1ms will also be lost.

```rust
# extern crate scylla;
# extern crate time;
# extern crate futures;
# use scylla::client::session::Session;
# use std::error::Error;
# async fn check_only_compiles(session: &Session) -> Result<(), Box<dyn Error>> {
use futures::TryStreamExt;
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time};

// 64.123 seconds since unix epoch, 1970-01-01 00:01:04.123
let to_insert = PrimitiveDateTime::new(
    Date::from_calendar_date(1970, Month::January, 1).unwrap(),
    Time::from_hms_milli(0, 1, 4, 123).unwrap(),
)
.assume_utc();

// Write timestamp to the table
session
    .query_unpaged("INSERT INTO keyspace.table (a) VALUES(?)", (to_insert,))
    .await?;

// Read timestamp from the table
let mut iter = session.query_iter("SELECT a FROM keyspace.table", &[])
    .await?
    .rows_stream::<(OffsetDateTime,)>()?;
while let Some((timestamp_value,)) = iter.try_next().await? {
    println!("{:?}", timestamp_value);
}
# Ok(())
# }
```
