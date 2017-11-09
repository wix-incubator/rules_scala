licenses(["notice"])  # 3-clause BSD

load("//scala:scala.bzl", "scala_library", "scala_library_for_plugin_bootstrapping")

scala_library_for_plugin_bootstrapping(
    name = "dependency_analyzer",
    srcs = ["io/bazel/rulesscala/dependencyanalyzer/DependencyAnalyzer.scala",
            ],
    resources = ["resources/scalac-plugin.xml"],
    visibility = ["//visibility:public"],
    deps = [
        "//external:io_bazel_rules_scala/dependency/scala/scala_compiler"
    ],
)
scala_library_for_plugin_bootstrapping(
    name = "dependency_analyzer2",
    srcs = glob(["zinc/xsbt/*.scala"]) + 
            glob(["zinc/xsbti/*.scala"]) + 
    		glob(["zinc/xsbti/api/*.scala"]) + 
    		glob(["zinc/xsbti/compile/*.scala"]),
    resources = ["resources/scalac-plugin.xml"],
    visibility = ["//visibility:public"],
    deps = [
        "//external:io_bazel_rules_scala/dependency/scala/scala_compiler"
    ],
)