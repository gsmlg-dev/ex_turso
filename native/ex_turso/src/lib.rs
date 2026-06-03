//! Rustler NIF bindings for the `turso` crate (local SQLite-compatible engine).
//!
//! The async `turso` API is driven from a single global Tokio runtime. Database
//! and connection handles are handed back to the BEAM as `ResourceArc`s wrapping
//! a `Mutex`, so their lifetimes are managed by the Erlang garbage collector.

use once_cell::sync::Lazy;
use rustler::{Encoder, Env, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::runtime::Runtime;
use turso::{Builder, Connection, Database, Value};

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Global multi-threaded Tokio runtime used to drive turso's async API.
static RT: Lazy<Runtime> = Lazy::new(|| Runtime::new().expect("failed to start Tokio runtime"));

/// Resource wrapping an open `turso::Database`.
struct DbResource {
    inner: Mutex<Database>,
}

#[rustler::resource_impl]
impl rustler::Resource for DbResource {}

/// Resource wrapping a `turso::Connection`.
struct ConnResource {
    inner: Mutex<Connection>,
}

#[rustler::resource_impl]
impl rustler::Resource for ConnResource {}

/// Resource wrapping an open `turso::sync::Database`.
struct SyncDbResource {
    inner: Mutex<turso::sync::Database>,
}

#[rustler::resource_impl]
impl rustler::Resource for SyncDbResource {}

/// A decoded SQL value ready to be encoded back into an Elixir term.
enum SqlValue {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl Encoder for SqlValue {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            SqlValue::Null => rustler::types::atom::nil().encode(env),
            SqlValue::Integer(i) => i.encode(env),
            SqlValue::Real(f) => f.encode(env),
            SqlValue::Text(s) => s.encode(env),
            SqlValue::Blob(bytes) => {
                let mut bin = rustler::OwnedBinary::new(bytes.len())
                    .expect("failed to allocate binary for blob");
                bin.as_mut_slice().copy_from_slice(bytes);
                bin.release(env).encode(env)
            }
        }
    }
}

impl From<Value> for SqlValue {
    fn from(value: Value) -> Self {
        match value {
            Value::Null => SqlValue::Null,
            Value::Integer(i) => SqlValue::Integer(i),
            Value::Real(f) => SqlValue::Real(f),
            Value::Text(s) => SqlValue::Text(s),
            Value::Blob(b) => SqlValue::Blob(b),
        }
    }
}

/// Decode an Elixir term into a `turso::Value` for use as a bound parameter.
///
/// Integers and floats map to `Integer`/`Real`, UTF-8 binaries to `Text`,
/// other binaries to `Blob`, and anything else (including `nil`) to `Null`.
fn term_to_value(term: &Term) -> Value {
    if let Ok(i) = term.decode::<i64>() {
        Value::Integer(i)
    } else if let Ok(f) = term.decode::<f64>() {
        Value::Real(f)
    } else if let Ok(s) = term.decode::<String>() {
        Value::Text(s)
    } else if let Ok(bin) = term.decode::<rustler::Binary>() {
        Value::Blob(bin.as_slice().to_vec())
    } else {
        Value::Null
    }
}

/// Open (or create) a local database file at `path`. `":memory:"` is supported.
#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> Result<ResourceArc<DbResource>, String> {
    let result = RT.block_on(async { Builder::new_local(&path).build().await });
    match result {
        Ok(db) => Ok(ResourceArc::new(DbResource {
            inner: Mutex::new(db),
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// Open a connection against a previously opened database.
#[rustler::nif(schedule = "DirtyIo")]
fn connect(db: ResourceArc<DbResource>) -> Result<ResourceArc<ConnResource>, String> {
    let guard = db.inner.lock().map_err(|e| e.to_string())?;
    match guard.connect() {
        Ok(conn) => Ok(ResourceArc::new(ConnResource {
            inner: Mutex::new(conn),
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// Open (or create) a local database synced with a remote database.
#[rustler::nif(schedule = "DirtyIo")]
fn open_sync(
    path: String,
    remote_url: String,
    auth_token: String,
) -> Result<ResourceArc<SyncDbResource>, String> {
    let result = RT.block_on(async {
        turso::sync::Builder::new_remote(&path)
            .with_remote_url(&remote_url)
            .with_auth_token(&auth_token)
            .build()
            .await
    });
    match result {
        Ok(db) => Ok(ResourceArc::new(SyncDbResource {
            inner: Mutex::new(db),
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// Open a connection against a synced database.
#[rustler::nif(schedule = "DirtyIo")]
fn connect_sync(
    db: ResourceArc<SyncDbResource>,
) -> Result<ResourceArc<ConnResource>, String> {
    let guard = db.inner.lock().map_err(|e| e.to_string())?;
    let conn = RT.block_on(async { guard.connect().await.map_err(|e| e.to_string()) })?;
    Ok(ResourceArc::new(ConnResource {
        inner: Mutex::new(conn),
    }))
}

/// Run bidirectional sync.
#[rustler::nif(schedule = "DirtyIo")]
fn sync(db: ResourceArc<SyncDbResource>) -> Result<rustler::types::atom::Atom, String> {
    let guard = db.inner.lock().map_err(|e| e.to_string())?;
    RT.block_on(async {
        guard.pull().await.map_err(|e| e.to_string())?;
        guard.push().await.map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    })?;
    Ok(atoms::ok())
}


/// Run a query and return its rows as a list of maps keyed by column name.
#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    env: Env<'a>,
    conn: ResourceArc<ConnResource>,
    sql: String,
    params: Vec<Term<'a>>,
) -> Result<Term<'a>, String> {
    let values: Vec<Value> = params.iter().map(term_to_value).collect();
    let guard = conn.inner.lock().map_err(|e| e.to_string())?;

    let rows: Vec<HashMap<String, SqlValue>> = RT.block_on(async {
        let mut rows = guard.query(&sql, values).await.map_err(|e| e.to_string())?;
        let columns = rows.column_names();
        let mut acc = Vec::new();

        while let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
            let mut map = HashMap::with_capacity(columns.len());
            for (idx, name) in columns.iter().enumerate() {
                let value = row.get_value(idx).map_err(|e| e.to_string())?;
                map.insert(name.clone(), SqlValue::from(value));
            }
            acc.push(map);
        }

        Ok::<_, String>(acc)
    })?;

    Ok(rows.encode(env))
}

/// Execute a statement and return the number of affected rows.
#[rustler::nif(schedule = "DirtyIo")]
fn execute<'a>(
    conn: ResourceArc<ConnResource>,
    sql: String,
    params: Vec<Term<'a>>,
) -> Result<u64, String> {
    let values: Vec<Value> = params.iter().map(term_to_value).collect();
    let guard = conn.inner.lock().map_err(|e| e.to_string())?;
    RT.block_on(async { guard.execute(&sql, values).await.map_err(|e| e.to_string()) })
}

/// Close a connection. turso closes the underlying connection when the resource
/// is dropped, so this releases held buffers best-effort and returns `:ok`.
#[rustler::nif(schedule = "DirtyIo")]
fn close(conn: ResourceArc<ConnResource>) -> rustler::types::atom::Atom {
    if let Ok(guard) = conn.inner.lock() {
        let _ = guard.cacheflush();
    }
    atoms::ok()
}

rustler::init!("Elixir.ExTurso.Native");
