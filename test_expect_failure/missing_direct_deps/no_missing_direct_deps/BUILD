package(default_visibility = ["//visibility:public"])
load("//scala:scala.bzl", "scala_library", "scala_test")

scala_library(
    name="a",
    srcs=[
        "A.scala",
        ],
    deps = ["b",],
)

scala_library(
    name="b",
    srcs=[
        "B.scala",
        ],
)

scala_library(
    name="c",
    srcs=[
        "C.scala",
        ],
    deps = ["a"],
)
