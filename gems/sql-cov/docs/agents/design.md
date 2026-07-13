# SQL-COV

## Design Document: SQL Expression-Level Coverage Engine (Spec: sql-cov)

This document serves as a blueprint for an LLM to implement a cross-dialect SQL expression-level code coverage tool in Rust.

## 1. System Overview & Architecture

The tool, sql-cov, instruments declarative SQL queries to track branch and expression coverage at the AST (Abstract Syntax Tree) layer. It maps execution metrics (evaluating to TRUE, FALSE, or UNKNOWN/NULL) back to source code character offsets to highlight untested logic.

### Structural Flow

```text
[ Raw SQL Query ]
       │
       ▼ (Parser Pass)
[ sqlparser::ast ] ──(Map Spans)──► [ Source Map Registry ]
       │
       ▼ (Instrumentation Pass)
[ Instrumented AST ]
       │
       ▼ (Generator Pass)
[ Telemetry SQL String ] ──► (Run Tests against Target DB) ──► [ Telemetry Rows ]
                                                                      │
                                                                      ▼
                                                              [ Coverage HTML UI ]
```

## 2. Core Modules

### Module A: parser.rs (AST Analysis & Source Mapping)

Dependency: sqlparser crate.

Responsibility: Parse incoming SQL files using the designated dialect (e.g., SQLiteDialect, PostgreSqlDialect). During the traversal of the AST, calculate the exact byte-offsets (spans) of all target conditional expressions.

Target Nodes: `Expr::BinaryOp`, `Expr::InSubquery`, `Expr::Between`, `Expr::IsNull`, `Expr::IsNotNull`.

### Module B: instrument.rs (Source-to-Source AST Rewriting)

Responsibility: Mutate the AST to capture the runtime behavior of every boolean expression.

Strategy: For a given query, extract the target conditional tree within `WHERE` or `JOIN` blocks and lift them into a tracked wrapper structure.

Implementation Trick: Rewrite queries by wrapping them in a Common Table Expression (CTE) or a derived subquery selection block.

Example Transformation (Targeting SQLite/Postgres compatibility)

Original Input Query:

```sql
SELECT name FROM users WHERE bonus != 0 AND age > 18;
```

Instrumented Output Query:

```sql
WITH __raw_target AS (
  SELECT
    *,
    (bonus != 0) AS __cov_id_0,
    (age > 18)   AS __cov_id_1
  FROM users
)
SELECT name FROM __raw_target WHERE __cov_id_0 AND __cov_id_1;
```

### Module C: driver.rs (Execution & Metrics Collection)

Responsibility: Manage database connections via sqlx (supporting SQLite and Postgres runtimes) to execute the instrumented queries during integration tests.

Data Aggregation: Intercept the returned rows, extract columns prefixed with `__cov_id_`, and map the results to a tracking matrix.

Ternary State Machine Matrix:

```text
1 → Condition evaluated to TRUE.
0 → Condition evaluated to FALSE.
NULL → Condition evaluated to UNKNOWN (Three-Valued Logic trap).
```

### Module D: reporter.rs (Source Map Alignment & UI)

Responsibility: Consolidate the runtime telemetry matrix with the structural character offsets recorded in parser.rs.

Output: Generate a standalone HTML report.

Fully Covered: Expression hit TRUE, FALSE, and NULL (if nullable) conditions across the test suite.

Partially Covered: Expression never evaluated to FALSE (e.g., test data always satisfied the branch), or hit a NULL poisoning state undetected by assertions.

## 3. Data Structures & Types

```rust
pub enum ThreeValuedLogicState {
    True,
    False,
    Unknown, // Represents NULL evaluations
}

pub struct ExpressionSpan {
    pub id: usize,
    pub start_offset: usize,
    pub end_offset: usize,
    pub raw_expression: String,
}

pub struct CoverageMetric {
    pub span: ExpressionSpan,
    pub hit_true_count: u64,
    pub hit_false_count: u64,
    pub hit_unknown_count: u64,
}

pub struct SourceFileCoverage {
    pub file_path: String,
    pub raw_source: String,
    pub metrics: Vec<CoverageMetric>,
}
```

## 4. LLM Implementation Steps

The implementation should proceed in four discrete stages to prevent context drift and compilation errors:

### Stage 1

Write the CLI infrastructure using clap and instantiate the sqlparser compiler frontend. Build a visitor pattern that prints the spans of binary operations inside a basic `WHERE` clause.

### Stage 2

Implement the AST rewriting logic in `instrument.rs`. Focus strictly on rewriting simple `SELECT ... WHERE ...` expressions into the nested CTE model shown above.

### Stage 3

Integrate sqlx to execute queries against an in-memory SQLite database instance. Build the row processing loop that decodes telemetry headers (`__cov_id_x`) into the `CoverageMetric` structure.

### Stage 4

Construct the reporter template. Use raw CSS string injections to span color-coded highlights over the original query text file bounds based on `CoverageMetric` counts.
