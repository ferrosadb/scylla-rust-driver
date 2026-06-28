use crate::frame::frame_errors::{
    ClusterChangeEventParseError, CqlEventParseError, SchemaChangeEventParseError,
};
use crate::frame::server_event_type::EventType;
use crate::frame::types;
use std::net::SocketAddr;

#[derive(Debug)]
pub enum Event {
    TopologyChange(TopologyChangeEvent),
    StatusChange(StatusChangeEvent),
    SchemaChange(SchemaChangeEvent),
}

#[derive(Debug)]
pub enum TopologyChangeEvent {
    NewNode(SocketAddr),
    RemovedNode(SocketAddr),
}

#[derive(Debug)]
pub enum StatusChangeEvent {
    Up(SocketAddr),
    Down(SocketAddr),
}

#[derive(Debug)]
pub enum SchemaChangeEvent {
    KeyspaceChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
    },
    TableChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
        object_name: String,
    },
    TypeChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
        type_name: String,
    },
    FunctionChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
        function_name: String,
        arguments: Vec<String>,
    },
    AggregateChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
        aggregate_name: String,
        arguments: Vec<String>,
    },
    /// Index was altered. Same wire format as TableChange: change_type, keyspace_name, index_name.
    IndexChange {
        change_type: SchemaChangeType,
        keyspace_name: String,
        object_name: String,
    },
}

#[derive(Debug)]
pub enum SchemaChangeType {
    Created,
    Updated,
    Dropped,
    Invalid,
}

impl Event {
    pub fn deserialize(buf: &mut &[u8]) -> Result<Self, CqlEventParseError> {
        let event_type: EventType = types::read_string(buf)
            .map_err(CqlEventParseError::EventTypeParseError)?
            .parse()?;
        match event_type {
            EventType::TopologyChange => Ok(Self::TopologyChange(
                TopologyChangeEvent::deserialize(buf)
                    .map_err(CqlEventParseError::TopologyChangeEventParseError)?,
            )),
            EventType::StatusChange => Ok(Self::StatusChange(
                StatusChangeEvent::deserialize(buf)
                    .map_err(CqlEventParseError::StatusChangeEventParseError)?,
            )),
            EventType::SchemaChange => Ok(Self::SchemaChange(SchemaChangeEvent::deserialize(buf)?)),
        }
    }
}

impl SchemaChangeEvent {
    pub fn deserialize(buf: &mut &[u8]) -> Result<Self, SchemaChangeEventParseError> {
        let type_of_change_string =
            types::read_string(buf).map_err(SchemaChangeEventParseError::TypeOfChangeParseError)?;
        let type_of_change = match type_of_change_string {
            "CREATED" => SchemaChangeType::Created,
            "UPDATED" => SchemaChangeType::Updated,
            "DROPPED" => SchemaChangeType::Dropped,
            _ => SchemaChangeType::Invalid,
        };

        let target =
            types::read_string(buf).map_err(SchemaChangeEventParseError::TargetTypeParseError)?;
        let keyspace_affected = types::read_string(buf)
            .map_err(SchemaChangeEventParseError::AffectedKeyspaceParseError)?
            .to_string();

        match target {
            "KEYSPACE" => Ok(Self::KeyspaceChange {
                change_type: type_of_change,
                keyspace_name: keyspace_affected,
            }),
            "TABLE" => {
                let table_name = types::read_string(buf)
                    .map_err(SchemaChangeEventParseError::AffectedTargetNameParseError)?
                    .to_string();
                Ok(Self::TableChange {
                    change_type: type_of_change,
                    keyspace_name: keyspace_affected,
                    object_name: table_name,
                })
            }
            "TYPE" => {
                let changed_type = types::read_string(buf)
                    .map_err(SchemaChangeEventParseError::AffectedTargetNameParseError)?
                    .to_string();
                Ok(Self::TypeChange {
                    change_type: type_of_change,
                    keyspace_name: keyspace_affected,
                    type_name: changed_type,
                })
            }
            "FUNCTION" => {
                let function = types::read_string(buf)
                    .map_err(SchemaChangeEventParseError::AffectedTargetNameParseError)?
                    .to_string();
                let number_of_arguments = types::read_short(buf).map_err(|err| {
                    SchemaChangeEventParseError::ArgumentCountParseError(err.into())
                })?;

                let mut argument_vector = Vec::with_capacity(number_of_arguments as usize);

                for _ in 0..number_of_arguments {
                    argument_vector.push(
                        types::read_string(buf)
                            .map_err(SchemaChangeEventParseError::FunctionArgumentParseError)?
                            .to_string(),
                    );
                }

                Ok(Self::FunctionChange {
                    change_type: type_of_change,
                    keyspace_name: keyspace_affected,
                    function_name: function,
                    arguments: argument_vector,
                })
            }
            "AGGREGATE" => {
                let name = types::read_string(buf)
                    .map_err(SchemaChangeEventParseError::AffectedTargetNameParseError)?
                    .to_string();
                let number_of_arguments = types::read_short(buf).map_err(|err| {
                    SchemaChangeEventParseError::ArgumentCountParseError(err.into())
                })?;

                let mut argument_vector = Vec::with_capacity(number_of_arguments as usize);

                for _ in 0..number_of_arguments {
                    argument_vector.push(
                        types::read_string(buf)
                            .map_err(SchemaChangeEventParseError::FunctionArgumentParseError)?
                            .to_string(),
                    );
                }

                Ok(Self::AggregateChange {
                    change_type: type_of_change,
                    keyspace_name: keyspace_affected,
                    aggregate_name: name,
                    arguments: argument_vector,
                })
            }

            "INDEX" => {
                let index_name = types::read_string(buf)
                    .map_err(SchemaChangeEventParseError::AffectedTargetNameParseError)?
                    .to_string();
                Ok(Self::IndexChange {
                    change_type: type_of_change,
                    keyspace_name: keyspace_affected,
                    object_name: index_name,
                })
            }

            _ => Err(SchemaChangeEventParseError::UnknownTargetOfSchemaChange(
                target.to_string(),
            )),
        }
    }
}

impl TopologyChangeEvent {
    pub fn deserialize(buf: &mut &[u8]) -> Result<Self, ClusterChangeEventParseError> {
        let type_of_change = types::read_string(buf)
            .map_err(ClusterChangeEventParseError::TypeOfChangeParseError)?;
        let addr =
            types::read_inet(buf).map_err(ClusterChangeEventParseError::NodeAddressParseError)?;

        match type_of_change {
            "NEW_NODE" => Ok(Self::NewNode(addr)),
            "REMOVED_NODE" => Ok(Self::RemovedNode(addr)),
            _ => Err(ClusterChangeEventParseError::UnknownTypeOfChange(
                type_of_change.to_string(),
            )),
        }
    }
}

impl StatusChangeEvent {
    pub fn deserialize(buf: &mut &[u8]) -> Result<Self, ClusterChangeEventParseError> {
        let type_of_change = types::read_string(buf)
            .map_err(ClusterChangeEventParseError::TypeOfChangeParseError)?;
        let addr =
            types::read_inet(buf).map_err(ClusterChangeEventParseError::NodeAddressParseError)?;

        match type_of_change {
            "UP" => Ok(Self::Up(addr)),
            "DOWN" => Ok(Self::Down(addr)),
            _ => Err(ClusterChangeEventParseError::UnknownTypeOfChange(
                type_of_change.to_string(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_string(buf: &mut Vec<u8>, s: &str) {
        buf.extend_from_slice(&(s.len() as u16).to_be_bytes());
        buf.extend_from_slice(s.as_bytes());
    }

    #[test]
    fn test_deserialize_index_change_created() {
        // SCHEMA_CHANGE event body: change_type="CREATED", target="INDEX",
        // keyspace="ks1", index_name="idx1"
        let mut body = Vec::new();
        write_string(&mut body, "CREATED");
        write_string(&mut body, "INDEX");
        write_string(&mut body, "ks1");
        write_string(&mut body, "idx1");

        let mut buf = &body[..];
        let event = SchemaChangeEvent::deserialize(&mut buf).unwrap();
        match event {
            SchemaChangeEvent::IndexChange {
                change_type,
                keyspace_name,
                object_name,
            } => {
                assert!(matches!(change_type, SchemaChangeType::Created));
                assert_eq!(keyspace_name, "ks1");
                assert_eq!(object_name, "idx1");
            }
            other => panic!("expected IndexChange, got {:?}", other),
        }
        assert!(buf.is_empty(), "buffer should be fully consumed");
    }

    #[test]
    fn test_deserialize_index_change_dropped() {
        let mut body = Vec::new();
        write_string(&mut body, "DROPPED");
        write_string(&mut body, "INDEX");
        write_string(&mut body, "my_ks");
        write_string(&mut body, "my_idx");

        let mut buf = &body[..];
        let event = SchemaChangeEvent::deserialize(&mut buf).unwrap();
        match event {
            SchemaChangeEvent::IndexChange {
                change_type,
                keyspace_name,
                object_name,
            } => {
                assert!(matches!(change_type, SchemaChangeType::Dropped));
                assert_eq!(keyspace_name, "my_ks");
                assert_eq!(object_name, "my_idx");
            }
            other => panic!("expected IndexChange, got {:?}", other),
        }
        assert!(buf.is_empty(), "buffer should be fully consumed");
    }

    #[test]
    fn test_deserialize_unknown_target_still_errors() {
        let mut body = Vec::new();
        write_string(&mut body, "CREATED");
        write_string(&mut body, "UNKNOWN_TARGET");
        write_string(&mut body, "ks1");

        let mut buf = &body[..];
        let result = SchemaChangeEvent::deserialize(&mut buf);
        assert!(result.is_err());
        match result.unwrap_err() {
            SchemaChangeEventParseError::UnknownTargetOfSchemaChange(target) => {
                assert_eq!(target, "UNKNOWN_TARGET");
            }
            other => panic!("expected UnknownTargetOfSchemaChange, got {:?}", other),
        }
    }
}
