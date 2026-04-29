use crate::runtime::value::Value;

pub enum ExecResult {
    Continue,
    Return(Value),
    /// A `ctl` handler called `resume expr` — carries the resumed value back to the effect call site.
    Resumed(Value),
}
