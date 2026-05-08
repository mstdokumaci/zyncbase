pub const AuthError = error{
    InvalidAuthConfig,
    MissingNamespaces,
    MissingStore,
    InvalidNamespaceRule,
    InvalidStoreRule,
    InvalidCondition,
    InvalidComparison,
    InvalidComparisonOperator,
    InvalidContextVariable,
    InvalidPattern,
    InvalidHook,
    InvalidValue,
    UnknownAuthKey,
    // Runtime evaluation errors
    ForbiddenVariableAccess,
    AccessDenied,
    HookNotSupported,
};
