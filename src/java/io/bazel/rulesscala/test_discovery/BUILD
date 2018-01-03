load("//scala:scala.bzl", "scala_library")

scala_library(
    name = "test_discovery",
    srcs = [
        "DiscoveredTestSuite.scala",
        "FilteredRunnerBuilder.scala",
        "ReflectionUtils.scala"
    ],
    visibility = ["//visibility:public"],
    deps = ["//external:io_bazel_rules_scala/dependency/junit/junit"]
            
)
