//! What an observed value's type domain is.
//!
//! A tracer answers questions only an interpreter can answer -- name this
//! object's class, sample its container, list a record's fields, find the file
//! its class was declared in -- and stops. What those answers *mean* is this
//! module: what counts as a shape, when two collections are the same shape,
//! singleton versus type, which names are test-only and must not be exported.
//!
//! None of that is language-specific, which is why it lives here rather than
//! being rewritten in C for every language with a shim.
//!
//! Two behaviours look like optimisations and are not. The shape memo is
//! *lossy by design*: a collection's shape is remembered against the classes it
//! was carrying, so the second collection of the same element class reuses the
//! first one's shape rather than describing itself. And shape ordering is by
//! JSON text, because that text is also what identifies a record layout.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

const COLLECTION_DEPTH: i64 = 3;
const RECORD_DEPTH: i64 = 2;
const UNTYPED: &str = "T.untyped";
const ANONYMOUS_RECORD_PREFIX: &str = "AnonymousStruct(";

/// One node of what a tracer saw. `class_id` is the identity of the value's
/// class within the traced process: two anonymous classes share the name
/// `T.untyped`, and the memo buckets on identity rather than on spelling.
#[derive(Debug, Clone, Deserialize)]
pub struct RawObservation {
    #[serde(rename = "type")]
    pub type_name: String,
    pub class_id: i64,
    #[serde(default)]
    pub singleton: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    pub kind: String,
    #[serde(default)]
    pub elements: Vec<RawObservation>,
    #[serde(default)]
    pub pairs: Vec<(RawObservation, RawObservation)>,
    #[serde(default)]
    pub fields: Vec<(String, RawObservation)>,
}

impl RawObservation {
    fn is_collection(&self) -> bool {
        matches!(self.kind.as_str(), "array" | "hash" | "set")
    }

    fn is_record(&self) -> bool {
        self.kind == "record"
    }
}

/// A shape, in the exact JSON shape the collector's C rules emit. `members` is
/// ordered by insertion, like the Ruby Hash it replaces, so its JSON text -- and
/// therefore the record layout it identifies -- is unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Shape {
    Class { kind: &'static str, name: String },
    Sequence { kind: &'static str, elements: Vec<Shape> },
    Mapping { kind: &'static str, keys: Vec<Shape>, values: Vec<Shape> },
    Record { kind: &'static str, name: String, members: Vec<(String, Shape)> },
}

impl Shape {
    fn untyped() -> Self {
        Shape::Class { kind: "class", name: UNTYPED.to_string() }
    }

    fn name(&self) -> Option<&str> {
        match self {
            Shape::Class { name, .. } | Shape::Record { name, .. } => Some(name),
            _ => None,
        }
    }

    fn is_named_kind(&self) -> bool {
        matches!(self, Shape::Class { .. } | Shape::Record { .. })
    }

    /// The JSON text a shape orders and identifies by. Written here rather than
    /// through a serializer so member order is exactly insertion order.
    fn json(&self) -> String {
        let mut out = String::new();
        self.write_json(&mut out);
        out
    }

    fn write_json(&self, out: &mut String) {
        match self {
            Shape::Class { kind, name } => {
                out.push_str("{\"kind\":");
                write_json_string(kind, out);
                out.push_str(",\"name\":");
                write_json_string(name, out);
                out.push('}');
            }
            Shape::Sequence { kind, elements } => {
                out.push_str("{\"kind\":");
                write_json_string(kind, out);
                out.push_str(",\"elements\":");
                write_json_list(elements, out);
                out.push('}');
            }
            Shape::Mapping { kind, keys, values } => {
                out.push_str("{\"kind\":");
                write_json_string(kind, out);
                out.push_str(",\"keys\":");
                write_json_list(keys, out);
                out.push_str(",\"values\":");
                write_json_list(values, out);
                out.push('}');
            }
            Shape::Record { kind, name, members } => {
                out.push_str("{\"kind\":");
                write_json_string(kind, out);
                out.push_str(",\"name\":");
                write_json_string(name, out);
                out.push_str(",\"members\":{");
                for (at, (member, shape)) in members.iter().enumerate() {
                    if at > 0 {
                        out.push(',');
                    }
                    write_json_string(member, out);
                    out.push(':');
                    shape.write_json(out);
                }
                out.push_str("}}");
            }
        }
    }
}

impl Shape {
    pub fn to_value(&self) -> Value {
        match self {
            Shape::Class { kind, name } => json!({"kind": kind, "name": name}),
            Shape::Sequence { kind, elements } => {
                json!({"kind": kind, "elements": values_of(elements)})
            }
            Shape::Mapping { kind, keys, values } => {
                json!({"kind": kind, "keys": values_of(keys), "values": values_of(values)})
            }
            Shape::Record { kind, name, members } => {
                let members = members
                    .iter()
                    .map(|(member, shape)| (member.clone(), shape.to_value()))
                    .collect::<serde_json::Map<_, _>>();
                json!({"kind": kind, "name": name, "members": members})
            }
        }
    }
}

impl ValueDomain {
    pub fn to_value(&self) -> Value {
        json!({
            "types": self.types,
            "singletons": self.singletons,
            "elements": self.elements,
            "keys": self.keys,
            "values": self.values,
            "shapes": values_of(&self.shapes),
            "nonproduction": self.nonproduction,
        })
    }
}

fn values_of(shapes: &[Shape]) -> Vec<Value> {
    shapes.iter().map(Shape::to_value).collect()
}

fn write_json_list(shapes: &[Shape], out: &mut String) {
    out.push('[');
    for (at, shape) in shapes.iter().enumerate() {
        if at > 0 {
            out.push(',');
        }
        shape.write_json(out);
    }
    out.push(']');
}

fn write_json_string(text: &str, out: &mut String) {
    out.push('"');
    for byte in text.bytes() {
        match byte {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            0x08 => out.push_str("\\b"),
            0x0c => out.push_str("\\f"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            _ if byte < 0x20 => out.push_str(&format!("\\u{byte:04x}")),
            _ => out.push(byte as char),
        }
    }
    out.push('"');
}

/// What a value was observed to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueDomain {
    pub types: Vec<String>,
    pub singletons: Vec<String>,
    pub elements: Vec<String>,
    pub keys: Vec<String>,
    pub values: Vec<String>,
    pub shapes: Vec<Shape>,
    pub nonproduction: Option<bool>,
}

/// The signature a collection's shape is remembered against: the one class every
/// sampled member shared, or nothing when they disagreed or any of them was
/// itself a collection.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Signature {
    Empty,
    Class(i64),
}

/// The state that makes the memo lossy across a run: which layout was seen
/// first for a given carried class, and which shape each key names.
///
/// It is deliberately long-lived. Two collections carrying the same class get
/// the same shape even when their contents differ, because that is what the
/// collector has always done and what its evidence describes.
#[derive(Debug, Default)]
pub struct DomainDeriver {
    shapes: BTreeMap<String, Shape>,
    sequence_memo: BTreeMap<(i64, Signature), String>,
    mapping_memo: BTreeMap<(Signature, Option<i64>), String>,
    /// Files the collect was told hold non-production code.
    nonproduction_paths: Vec<String>,
    /// Every type name seen, and the file its class was declared in, so a name
    /// appearing inside a shape can be judged without resolving a constant.
    sources: BTreeMap<String, Option<String>>,
}

impl DomainDeriver {
    pub fn new(nonproduction_paths: Vec<String>) -> Self {
        Self { nonproduction_paths, ..Self::default() }
    }

    pub fn derive(&mut self, raw: &RawObservation) -> ValueDomain {
        self.learn_sources(raw);
        let mut domain = self.observed(raw);
        domain.nonproduction = raw.source.as_ref().map(|path| self.is_nonproduction(path));
        domain
    }

    /// A name inside a shape is judged by the file its class was declared in,
    /// which the tracer reported next to every value it named.
    fn learn_sources(&mut self, raw: &RawObservation) {
        self.sources.entry(raw.type_name.clone()).or_insert_with(|| raw.source.clone());
        for element in &raw.elements {
            self.learn_sources(element);
        }
        for (key, value) in &raw.pairs {
            self.learn_sources(key);
            self.learn_sources(value);
        }
        for (_, value) in &raw.fields {
            self.learn_sources(value);
        }
    }

    fn is_nonproduction(&self, path: &str) -> bool {
        self.nonproduction_paths.iter().any(|listed| listed == path)
    }

    fn nonproduction_name(&self, name: &str) -> bool {
        if name.is_empty() || name == UNTYPED || name.starts_with(ANONYMOUS_RECORD_PREFIX) {
            return false;
        }
        self.sources
            .get(name)
            .and_then(|source| source.as_deref())
            .is_some_and(|path| self.is_nonproduction(path))
    }

    fn observed(&mut self, raw: &RawObservation) -> ValueDomain {
        let mut types = vec![raw.type_name.clone()];
        let singletons = raw.singleton.iter().cloned().collect::<Vec<_>>();
        let mut elements = Vec::new();
        let mut keys = Vec::new();
        let mut values = Vec::new();
        let mut shapes = Vec::new();

        if let Some(key) = self.record_shape_key(raw, RECORD_DEPTH) {
            let payload = self.payload(&key);
            // A record whose class is anonymous is better described by its
            // layout than by the absence of a name.
            if let Some(name) = payload.name() {
                if types.len() == 1 && types[0] == UNTYPED {
                    types = vec![name.to_string()];
                }
            }
            shapes.push(payload);
        }

        match raw.kind.as_str() {
            "array" | "set" => {
                for element in &raw.elements {
                    push_unique(&mut elements, &element.type_name);
                }
            }
            "hash" => {
                for (key, value) in &raw.pairs {
                    push_unique(&mut keys, &key.type_name);
                    push_unique(&mut values, &value.type_name);
                }
            }
            _ => {}
        }
        if raw.is_collection() {
            let key = self.collection_shape_key(raw, COLLECTION_DEPTH);
            let payload = self.payload(&key);
            if let Some(shape) = self.production_shape(&payload) {
                shapes.push(shape);
            }
        }

        elements.retain(|name| !self.nonproduction_name(name));
        keys.retain(|name| !self.nonproduction_name(name));
        values.retain(|name| !self.nonproduction_name(name));
        shapes.sort_by_cached_key(Shape::json);

        ValueDomain {
            types: sorted(types),
            singletons: sorted(singletons),
            elements: sorted(elements),
            keys: sorted(keys),
            values: sorted(values),
            shapes,
            nonproduction: None,
        }
    }

    // ------------------------------------------------------------- shapes

    fn remember(&mut self, key: String, shape: Shape) -> String {
        self.shapes.entry(key.clone()).or_insert(shape);
        key
    }

    fn payload(&self, key: &str) -> Shape {
        self.shapes.get(key).cloned().unwrap_or_else(Shape::untyped)
    }

    fn payloads(&self, keys: &[String]) -> Vec<Shape> {
        keys.iter().map(|key| self.payload(key)).collect()
    }

    fn class_shape_key(&mut self, raw: &RawObservation) -> String {
        let key = format!("class:{}", raw.type_name);
        let shape = Shape::Class { kind: "class", name: raw.type_name.clone() };
        self.remember(key, shape)
    }

    /// A record's own type name, or its field list when the class is anonymous.
    fn record_type_name(&self, raw: &RawObservation) -> String {
        if raw.type_name != UNTYPED {
            return raw.type_name.clone();
        }
        let fields = raw.fields.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>();
        format!("{ANONYMOUS_RECORD_PREFIX}{})", fields.join(","))
    }

    fn record_member_shape(&mut self, raw: &RawObservation, depth: i64) -> Shape {
        if depth <= 0 {
            let key = self.class_shape_key(raw);
            return self.payload(&key);
        }
        if let Some(key) = self.record_shape_key(raw, depth - 1) {
            return self.payload(&key);
        }
        if raw.is_collection() {
            let key = self.collection_shape_key(raw, depth - 1);
            return self.payload(&key);
        }
        let key = self.class_shape_key(raw);
        self.payload(&key)
    }

    fn record_shape_key(&mut self, raw: &RawObservation, depth: i64) -> Option<String> {
        if !raw.is_record() {
            return None;
        }
        let mut members: Vec<(String, Shape)> = Vec::new();
        let mut signature = Vec::new();
        for (name, value) in &raw.fields {
            if name.is_empty() {
                continue;
            }
            let shape = self.record_member_shape(value, depth);
            signature.push(format!("{name}={}", shape.json()));
            // Insertion order, and a repeated field name replaces in place --
            // exactly what assigning into a Ruby Hash did.
            match members.iter_mut().find(|(existing, _)| existing == name) {
                Some(slot) => slot.1 = shape,
                None => members.push((name.clone(), shape)),
            }
        }
        if members.is_empty() {
            return None;
        }
        let name = self.record_type_name(raw);
        let key = format!("record:{name}:{}", signature.join("\\0"));
        let shape = Shape::Record { kind: "record", name, members };
        Some(self.remember(key, shape))
    }

    fn shape_key_full(&mut self, raw: &RawObservation, depth: i64) -> String {
        // A sampled member may itself be a record; that layout belongs under
        // the collection so a block binding still sees it.
        if let Some(key) = self.record_shape_key(raw, RECORD_DEPTH) {
            return key;
        }
        if depth <= 0 {
            return self.class_shape_key(raw);
        }
        match raw.kind.as_str() {
            kind @ ("array" | "set") => {
                let mut keys = Vec::new();
                for element in &raw.elements {
                    let key = self.collection_shape_key(element, depth - 1);
                    keys.push(key);
                }
                let keys = unique_sorted(keys);
                let shape = Shape::Sequence {
                    kind: if kind == "array" { "array" } else { "set" },
                    elements: self.payloads(&keys),
                };
                self.remember(format!("{kind}:[{}]", keys.join(";")), shape)
            }
            "hash" => {
                let mut key_shapes = Vec::new();
                let mut value_shapes = Vec::new();
                for (key, value) in &raw.pairs {
                    let observed = self.collection_shape_key(key, depth - 1);
                    key_shapes.push(observed);
                    let observed = self.collection_shape_key(value, depth - 1);
                    value_shapes.push(observed);
                }
                let key_shapes = unique_sorted(key_shapes);
                let value_shapes = unique_sorted(value_shapes);
                let shape = Shape::Mapping {
                    kind: "hash",
                    keys: self.payloads(&key_shapes),
                    values: self.payloads(&value_shapes),
                };
                self.remember(
                    format!("hash:{{{}}}:{{{}}}", key_shapes.join(";"), value_shapes.join(";")),
                    shape,
                )
            }
            _ => self.class_shape_key(raw),
        }
    }

    /// The memo is the behaviour, not an optimisation: a collection's shape is
    /// remembered against the classes it was carrying, so a second collection
    /// of the same element class reuses the first one's shape.
    fn collection_shape_key(&mut self, raw: &RawObservation, depth: i64) -> String {
        if depth > 0 {
            match raw.kind.as_str() {
                "array" | "set" => {
                    if let Some(signature) = homogeneous_element(raw) {
                        let bucket = (raw.class_id, signature);
                        if let Some(known) = self.sequence_memo.get(&bucket) {
                            return known.clone();
                        }
                        let key = self.shape_key_full(raw, depth);
                        self.sequence_memo.insert(bucket, key.clone());
                        return key;
                    }
                }
                "hash" => {
                    if let Some((keys, values)) = homogeneous_pair(raw) {
                        let bucket = (keys, values);
                        if let Some(known) = self.mapping_memo.get(&bucket) {
                            return known.clone();
                        }
                        let key = self.shape_key_full(raw, depth);
                        self.mapping_memo.insert(bucket, key.clone());
                        return key;
                    }
                }
                _ => {}
            }
        }
        self.shape_key_full(raw, depth)
    }

    /// A shape naming a test-only class must not be exported, and neither must a
    /// member of one. The rest of the shape survives.
    fn production_shape(&self, shape: &Shape) -> Option<Shape> {
        if shape.is_named_kind() && shape.name().is_some_and(|name| self.nonproduction_name(name)) {
            return None;
        }
        Some(match shape {
            Shape::Class { .. } => shape.clone(),
            Shape::Sequence { kind, elements } => Shape::Sequence {
                kind,
                elements: elements.iter().filter_map(|shape| self.production_shape(shape)).collect(),
            },
            Shape::Mapping { kind, keys, values } => Shape::Mapping {
                kind,
                keys: keys.iter().filter_map(|shape| self.production_shape(shape)).collect(),
                values: values.iter().filter_map(|shape| self.production_shape(shape)).collect(),
            },
            Shape::Record { kind, name, members } => Shape::Record {
                kind,
                name: name.clone(),
                members: members
                    .iter()
                    .filter_map(|(member, shape)| {
                        self.production_shape(shape).map(|shape| (member.clone(), shape))
                    })
                    .collect(),
            },
        })
    }
}

/// The one class every sampled member shared. `None` when they disagreed or any
/// of them was itself a collection -- the memo must not conflate those.
fn homogeneous_element(raw: &RawObservation) -> Option<Signature> {
    if raw.elements.is_empty() {
        return Some(Signature::Empty);
    }
    let first = raw.elements[0].class_id;
    for element in &raw.elements {
        if element.is_collection() || element.class_id != first {
            return None;
        }
    }
    Some(Signature::Class(first))
}

/// The same question for a mapping. The value class stays unset for an empty
/// mapping, matching the collector it replaces.
fn homogeneous_pair(raw: &RawObservation) -> Option<(Signature, Option<i64>)> {
    let mut keys: Option<i64> = None;
    let mut values: Option<i64> = None;
    for (at, (key, value)) in raw.pairs.iter().enumerate() {
        if key.is_collection() || value.is_collection() {
            return None;
        }
        if at == 0 {
            keys = Some(key.class_id);
            values = Some(value.class_id);
        } else if Some(key.class_id) != keys || Some(value.class_id) != values {
            return None;
        }
    }
    Some((keys.map_or(Signature::Empty, Signature::Class), values))
}

fn push_unique(names: &mut Vec<String>, name: &str) {
    if !names.iter().any(|existing| existing == name) {
        names.push(name.to_string());
    }
}

fn sorted(mut names: Vec<String>) -> Vec<String> {
    names.sort();
    names
}

fn unique_sorted(keys: Vec<String>) -> Vec<String> {
    let mut unique = keys;
    unique.sort();
    unique.dedup();
    unique
}
