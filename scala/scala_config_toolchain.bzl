def _scala_config_toolchain_impl(ctx):
    toolchain = platform_common.ToolchainInfo(
        scalacopts = ctx.attr.scalacopts,
        unused_dependency_checker_mode = ctx.attr.unused_dependency_checker_mode,
        plus_one_deps_mode = ctx.attr.plus_one_deps_mode,
        enable_code_coverage_aspect = ctx.attr.enable_code_coverage_aspect,
    )
    return [toolchain]

scala_config_toolchain = rule(
    _scala_config_toolchain_impl,
    attrs = {
        "scalacopts": attr.string_list(),
        "unused_dependency_checker_mode": attr.string(
            default = "off",
            values = ["off", "warn", "error"],
        ),
        "plus_one_deps_mode": attr.string(
            default = "off",
            values = ["off", "on"],
        ),
        "enable_code_coverage_aspect": attr.string(
            default = "off",
            values = ["off", "on"],
        )
    },
)
