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
    InvalidValue,
    UnknownAuthKey,
    // Runtime evaluation errors
    ForbiddenVariableAccess,
    AccessDenied,
};
