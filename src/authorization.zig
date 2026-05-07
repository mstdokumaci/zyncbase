const types = @import("authorization/types.zig");
const defaults = @import("authorization/defaults.zig");
const pattern_mod = @import("authorization/pattern.zig");
const evaluate_mod = @import("authorization/evaluate.zig");
const inject_mod = @import("authorization/inject.zig");
const errors = @import("authorization/errors.zig");

pub const AuthConfig = types.AuthConfig;
pub const NamespaceRule = types.NamespaceRule;
pub const StoreRule = types.StoreRule;
pub const Condition = types.Condition;
pub const Comparison = types.Comparison;
pub const ComparisonOp = types.ComparisonOp;
pub const ContextVar = types.ContextVar;
pub const VarScope = types.VarScope;
pub const Value = types.Value;
pub const PatternSegment = types.PatternSegment;

pub const AuthError = errors.AuthError;

pub const implicitConfig = defaults.implicitConfig;

pub const PatternMatch = pattern_mod.PatternMatch;
pub const matchNamespace = pattern_mod.matchNamespace;
pub const parsePattern = pattern_mod.parsePattern;

pub const EvalContext = evaluate_mod.EvalContext;
pub const EvalResult = evaluate_mod.EvalResult;
pub const evaluateCondition = evaluate_mod.evaluateCondition;
pub const evaluateConditionStrict = evaluate_mod.evaluateConditionStrict;
pub const authorizeStoreNamespace = evaluate_mod.authorizeStoreNamespace;

pub const InjectedClause = inject_mod.InjectedClause;
pub const injectDocCondition = inject_mod.injectDocCondition;
pub const cloneBindValues = inject_mod.cloneBindValues;
pub const deinitBindValues = inject_mod.deinitBindValues;
