use jiff::civil::Date;
use jiff::Span;
use scylla_cql::frame::{
    response::result::CqlValue,
    value::{CqlDate, CqlTime, CqlTimestamp},
};

use std::borrow::Borrow;
use std::fmt::{Display, LowerHex, UpperHex};
use std::time::{SystemTime, UNIX_EPOCH};

const MILLIS_PER_DAY: i64 = 86_400_000;
const NANOS_PER_DAY: i128 = 86_400_000_000_000;

/// The civil date `days` after 1970-01-01, or `None` outside jiff's
/// calendar (years -9999..=9999).
fn date_from_days(days: i64) -> Option<Date> {
    let span = Span::new().try_days(days).ok()?;
    Date::constant(1970, 1, 1).checked_add(span).ok()
}

/// `YYYY-MM-DD`, with the year written the way chrono wrote it: four digits
/// in 0..=9999, otherwise signed (`-0001`, `+10000`).
fn write_date(f: &mut std::fmt::Formatter<'_>, date: Date) -> std::fmt::Result {
    let year = date.year();
    if (0..=9999).contains(&year) {
        write!(f, "{:04}", year)?;
    } else {
        write!(f, "{:+05}", year)?;
    }
    write!(f, "-{:02}-{:02}", date.month(), date.day())
}

/// Displays a [`SystemTime`] as `YYYY-MM-DD HH:MM:SS[.fraction] UTC`, the
/// format chrono's `DateTime<Utc>` used: the fraction is left out when zero
/// and otherwise written at millisecond, microsecond or nanosecond width,
/// whichever represents it exactly.
pub(crate) struct TimePointDisplayer(pub(crate) SystemTime);

impl Display for TimePointDisplayer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let nanos_since_epoch: i128 = match self.0.duration_since(UNIX_EPOCH) {
            Ok(after) => after.as_nanos() as i128,
            Err(before) => -(before.duration().as_nanos() as i128),
        };
        let days = nanos_since_epoch.div_euclid(NANOS_PER_DAY);
        let of_day = nanos_since_epoch.rem_euclid(NANOS_PER_DAY);
        let Some(date) = i64::try_from(days).ok().and_then(date_from_days) else {
            return f.write_str("<time out of representable range>");
        };
        let secs_of_day = of_day / 1_000_000_000;
        let nanos = of_day % 1_000_000_000;
        write_date(f, date)?;
        write!(
            f,
            " {:02}:{:02}:{:02}",
            secs_of_day / 3600,
            secs_of_day / 60 % 60,
            secs_of_day % 60
        )?;
        if nanos == 0 {
        } else if nanos % 1_000_000 == 0 {
            write!(f, ".{:03}", nanos / 1_000_000)?;
        } else if nanos % 1_000 == 0 {
            write!(f, ".{:06}", nanos / 1_000)?;
        } else {
            write!(f, ".{:09}", nanos)?;
        }
        f.write_str(" UTC")
    }
}

pub(crate) struct HexBytes<'a>(pub(crate) &'a [u8]);

impl LowerHex for HexBytes<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for b in self.0 {
            write!(f, "{:02x}", b)?;
        }
        Ok(())
    }
}

impl UpperHex for HexBytes<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for b in self.0 {
            write!(f, "{:02X}", b)?;
        }
        Ok(())
    }
}

// Displays a CqlValue. The syntax should resemble the CQL literal syntax
// (but no guarantee is given that it's always the same).
pub(crate) struct CqlValueDisplayer<C>(pub(crate) C);

impl<C> Display for CqlValueDisplayer<C>
where
    C: Borrow<CqlValue>,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.0.borrow() {
            // Scalar types
            CqlValue::Ascii(a) => write!(f, "{}", CqlStringLiteralDisplayer(a))?,
            CqlValue::Text(t) => write!(f, "{}", CqlStringLiteralDisplayer(t))?,
            CqlValue::Blob(b) => write!(f, "0x{:x}", HexBytes(b))?,
            CqlValue::Empty => write!(f, "0x")?,
            CqlValue::Decimal(d) => {
                let (bytes, scale) = d.as_signed_be_bytes_slice_and_exponent();
                write!(
                    f,
                    "blobAsDecimal(0x{:x}{:x})",
                    HexBytes(&scale.to_be_bytes()),
                    HexBytes(bytes)
                )?
            }
            CqlValue::Float(fl) => write!(f, "{}", fl)?,
            CqlValue::Double(d) => write!(f, "{}", d)?,
            CqlValue::Boolean(b) => write!(f, "{}", b)?,
            CqlValue::Int(i) => write!(f, "{}", i)?,
            CqlValue::BigInt(bi) => write!(f, "{}", bi)?,
            CqlValue::Inet(i) => write!(f, "'{}'", i)?,
            CqlValue::SmallInt(si) => write!(f, "{}", si)?,
            CqlValue::TinyInt(ti) => write!(f, "{}", ti)?,
            CqlValue::Varint(vi) => write!(
                f,
                "blobAsVarint(0x{:x})",
                HexBytes(vi.as_signed_bytes_be_slice())
            )?,
            CqlValue::Counter(c) => write!(f, "{}", c.0)?,
            CqlValue::Date(CqlDate(d)) => {
                // date_days is u32 then converted to i64 then we subtract 2^31.
                match date_from_days(*d as i64 - (1 << 31)) {
                    Some(date) => {
                        f.write_str("'")?;
                        write_date(f, date)?;
                        f.write_str("'")?;
                    }
                    None => f.write_str("<date out of representable range>")?,
                }
            }
            CqlValue::Duration(d) => write!(f, "{}mo{}d{}ns", d.months, d.days, d.nanoseconds)?,
            CqlValue::Time(CqlTime(t)) => {
                write!(
                    f,
                    "'{:02}:{:02}:{:02}.{:09}'",
                    t / 3_600_000_000_000,
                    t / 60_000_000_000 % 60,
                    t / 1_000_000_000 % 60,
                    t % 1_000_000_000,
                )?;
            }
            CqlValue::Timestamp(CqlTimestamp(t)) => {
                let millis_of_day = t.rem_euclid(MILLIS_PER_DAY);
                match date_from_days(t.div_euclid(MILLIS_PER_DAY)) {
                    Some(date) => {
                        f.write_str("'")?;
                        write_date(f, date)?;
                        write!(
                            f,
                            " {:02}:{:02}:{:02}.{:03}+0000'",
                            millis_of_day / 3_600_000,
                            millis_of_day / 60_000 % 60,
                            millis_of_day / 1_000 % 60,
                            millis_of_day % 1_000,
                        )?
                    }
                    None => f.write_str("<timestamp out of representable range>")?,
                }
            }
            CqlValue::Timeuuid(t) => write!(f, "{}", t)?,
            CqlValue::Uuid(u) => write!(f, "{}", u)?,

            // Compound types
            CqlValue::Tuple(t) => {
                f.write_str("(")?;
                CommaSeparatedDisplayer(
                    t.iter()
                        .map(|x| MaybeNullDisplayer(x.as_ref().map(CqlValueDisplayer))),
                )
                .fmt(f)?;
                f.write_str(")")?;
            }
            CqlValue::List(v) => {
                f.write_str("[")?;
                CommaSeparatedDisplayer(v.iter().map(CqlValueDisplayer)).fmt(f)?;
                f.write_str("]")?;
            }
            CqlValue::Set(v) => {
                f.write_str("{")?;
                CommaSeparatedDisplayer(v.iter().map(CqlValueDisplayer)).fmt(f)?;
                f.write_str("}")?;
            }
            CqlValue::Map(m) => {
                f.write_str("{")?;
                CommaSeparatedDisplayer(
                    m.iter()
                        .map(|(k, v)| PairDisplayer(CqlValueDisplayer(k), CqlValueDisplayer(v))),
                )
                .fmt(f)?;
                f.write_str("}")?;
            }
            CqlValue::UserDefinedType {
                keyspace: _,
                type_name: _,
                fields,
            } => {
                f.write_str("{")?;
                CommaSeparatedDisplayer(fields.iter().map(|(k, v)| {
                    PairDisplayer(k, MaybeNullDisplayer(v.as_ref().map(CqlValueDisplayer)))
                }))
                .fmt(f)?;
                f.write_str("}")?;
            }
        }
        Ok(())
    }
}

pub(crate) struct CqlStringLiteralDisplayer<'a>(&'a str);

impl Display for CqlStringLiteralDisplayer<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // CQL string literals use single quotes. The only character that
        // needs escaping is singular quote, and escaping is done by repeating
        // the quote character.
        f.write_str("'")?;
        let mut first = true;
        for part in self.0.split('\'') {
            if first {
                first = false;
            } else {
                f.write_str("''")?;
            }
            f.write_str(part)?;
        }
        f.write_str("'")?;
        Ok(())
    }
}

pub(crate) struct CommaSeparatedDisplayer<I>(pub(crate) I);

impl<I, T> Display for CommaSeparatedDisplayer<I>
where
    I: Iterator<Item = T> + Clone,
    T: Display,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut first = true;
        for t in self.0.clone() {
            if first {
                first = false;
            } else {
                f.write_str(",")?;
            }
            write!(f, "{}", t)?;
        }
        Ok(())
    }
}

pub(crate) struct PairDisplayer<K, V>(K, V);

impl<K, V> Display for PairDisplayer<K, V>
where
    K: Display,
    V: Display,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.0, self.1)
    }
}

pub(crate) struct MaybeNullDisplayer<T>(Option<T>);

impl<T> Display for MaybeNullDisplayer<T>
where
    T: Display,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.0 {
            None => write!(f, "null")?,
            Some(v) => write!(f, "{}", v)?,
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use scylla_cql::frame::response::result::CqlValue;
    use scylla_cql::frame::value::{CqlDate, CqlDecimal, CqlDuration, CqlTime, CqlTimestamp};

    use crate::test_utils::setup_tracing;
    use crate::utils::pretty::CqlValueDisplayer;

    #[test]
    fn test_cql_value_displayer() {
        setup_tracing();
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Boolean(true))),
            "true"
        );
        assert_eq!(format!("{}", CqlValueDisplayer(CqlValue::Int(123))), "123");
        assert_eq!(
            format!(
                "{}",
                // 123.456
                CqlValueDisplayer(CqlValue::Decimal(
                    CqlDecimal::from_signed_be_bytes_and_exponent(vec![0x01, 0xE2, 0x40], 3)
                ))
            ),
            "blobAsDecimal(0x0000000301e240)"
        );
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Float(12.75))),
            "12.75"
        );
        assert_eq!(
            format!(
                "{}",
                CqlValueDisplayer(CqlValue::Text("Ala ma kota".to_owned()))
            ),
            "'Ala ma kota'"
        );
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Text("Foo's".to_owned()))),
            "'Foo''s'"
        );

        // Time types are the most tricky
        assert_eq!(
            format!(
                "{}",
                CqlValueDisplayer(CqlValue::Date(CqlDate(40 + (1 << 31))))
            ),
            "'1970-02-10'"
        );
        assert_eq!(
            format!(
                "{}",
                CqlValueDisplayer(CqlValue::Duration(CqlDuration {
                    months: 1,
                    days: 2,
                    nanoseconds: 3,
                }))
            ),
            "1mo2d3ns"
        );
        // 06:05:04.000000123
        let t = ((6 * 60 + 5) * 60 + 4) * 1_000_000_000 + 123;
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Time(CqlTime(t)))),
            "'06:05:04.000000123'"
        );

        // 2005-04-02 19:37:42 UTC
        assert_eq!(
            format!(
                "{}",
                CqlValueDisplayer(CqlValue::Timestamp(CqlTimestamp(1_112_470_662_000)))
            ),
            "'2005-04-02 19:37:42.000+0000'"
        );

        // Compound types
        let list_or_set = vec![CqlValue::Int(1), CqlValue::Int(3), CqlValue::Int(2)];
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::List(list_or_set.clone()))),
            "[1,3,2]"
        );
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Set(list_or_set.clone()))),
            "{1,3,2}"
        );

        let tuple: Vec<_> = list_or_set
            .into_iter()
            .map(Some)
            .chain(std::iter::once(None))
            .collect();
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Tuple(tuple))),
            "(1,3,2,null)"
        );

        let map = vec![
            (CqlValue::Text("foo".to_owned()), CqlValue::Int(123)),
            (CqlValue::Text("bar".to_owned()), CqlValue::Int(321)),
        ];
        assert_eq!(
            format!("{}", CqlValueDisplayer(CqlValue::Map(map))),
            "{'foo':123,'bar':321}"
        );

        let fields = vec![
            ("foo".to_owned(), Some(CqlValue::Int(123))),
            ("bar".to_owned(), Some(CqlValue::Int(321))),
        ];
        assert_eq!(
            format!(
                "{}",
                CqlValueDisplayer(CqlValue::UserDefinedType {
                    keyspace: "ks".to_owned(),
                    type_name: "typ".to_owned(),
                    fields,
                })
            ),
            "{foo:123,bar:321}"
        );
    }

    /// `date` is days since the epoch, offset by 2^31.
    fn date_at(days_since_epoch: i64) -> String {
        let raw = u32::try_from(days_since_epoch + (1 << 31)).unwrap();
        format!("{}", CqlValueDisplayer(CqlValue::Date(CqlDate(raw))))
    }

    fn timestamp_at(millis: i64) -> String {
        format!(
            "{}",
            CqlValueDisplayer(CqlValue::Timestamp(CqlTimestamp(millis)))
        )
    }

    use super::MILLIS_PER_DAY;

    // These strings were taken from the chrono implementation before it was
    // replaced, so the replacement is held to printing the same bytes.
    #[test]
    fn date_display_is_pinned() {
        assert_eq!(date_at(0), "'1970-01-01'");
        assert_eq!(date_at(-1), "'1969-12-31'");
        assert_eq!(date_at(11_016), "'2000-02-29'");
        assert_eq!(date_at(12_875), "'2005-04-02'");
        assert_eq!(date_at(-719_528), "'0000-01-01'");
        assert_eq!(date_at(-719_529), "'-0001-12-31'");
        assert_eq!(date_at(2_932_896), "'9999-12-31'");
        assert_eq!(date_at(-4_371_587), "'-9999-01-01'");
        // The extremes of the `date` type are far outside any calendar library.
        assert_eq!(date_at((1 << 31) - 1), "<date out of representable range>");
        assert_eq!(date_at(-(1 << 31)), "<date out of representable range>");
    }

    #[test]
    fn timestamp_display_is_pinned() {
        assert_eq!(timestamp_at(0), "'1970-01-01 00:00:00.000+0000'");
        assert_eq!(timestamp_at(-1), "'1969-12-31 23:59:59.999+0000'");
        assert_eq!(timestamp_at(1), "'1970-01-01 00:00:00.001+0000'");
        assert_eq!(
            timestamp_at(1_112_470_662_042),
            "'2005-04-02 19:37:42.042+0000'"
        );
        assert_eq!(
            timestamp_at(11_016 * MILLIS_PER_DAY + 86_399_999),
            "'2000-02-29 23:59:59.999+0000'"
        );
        assert_eq!(
            timestamp_at(-719_528 * MILLIS_PER_DAY),
            "'0000-01-01 00:00:00.000+0000'"
        );
        assert_eq!(
            timestamp_at(-719_528 * MILLIS_PER_DAY - 1),
            "'-0001-12-31 23:59:59.999+0000'"
        );
        assert_eq!(
            timestamp_at(2_932_897 * MILLIS_PER_DAY - 1),
            "'9999-12-31 23:59:59.999+0000'"
        );
        assert_eq!(
            timestamp_at(-4_371_587 * MILLIS_PER_DAY),
            "'-9999-01-01 00:00:00.000+0000'"
        );
        assert_eq!(
            timestamp_at(i64::MAX),
            "<timestamp out of representable range>"
        );
        assert_eq!(
            timestamp_at(i64::MIN),
            "<timestamp out of representable range>"
        );
    }

    // Years past 9999 in either direction. chrono printed these
    // ('+10000-01-01', '-10000-12-31'); jiff's civil calendar stops at
    // +/-9999, so they are now reported as out of range. This is the one
    // deliberate change in output.
    #[test]
    fn dates_beyond_year_9999() {
        assert_eq!(date_at(2_932_897), "<date out of representable range>");
        assert_eq!(date_at(-4_371_588), "<date out of representable range>");
        assert_eq!(
            timestamp_at(2_932_897 * MILLIS_PER_DAY),
            "<timestamp out of representable range>"
        );
    }
}
