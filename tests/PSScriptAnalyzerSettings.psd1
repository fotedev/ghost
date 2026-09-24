@{
    # Default rule set. CI invokes with -Severity Error, so style warnings
    # (e.g. PSAvoidUsingWriteHost, which every reset script relies on for its
    # console UX) stay visible but non-blocking.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Console output IS the product's UX for these scripts.
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingCmdletAliases'
    )
}
