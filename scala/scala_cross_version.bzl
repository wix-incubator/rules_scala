# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@io_bazel_rules_scala//scala:scala_maven_import_external.bzl",
    _scala_maven_import_external = "scala_maven_import_external",
)

"""Helper functions for Scala cross-version support. Encapsulates the logic
of abstracting over Scala major version (2.11, 2.12, etc) for dependency
resolution."""

def default_scala_version():
    """return the scala version for use in maven coordinates"""
    return "2.11.12"

def default_scala_version_jar_shas():
    return {
        "scala_compiler": "3e892546b72ab547cb77de4d840bcfd05c853e73390fed7370a8f19acb0735a0",
        "scala_compiler_sources": "d57797fe3982d69d56d432046459f5b72e87a422170d98cf295c3b1bbe93f456",
        "scala_library": "0b3d6fd42958ee98715ba2ec5fe221f4ca1e694d7c981b0ae0cd68e97baf6dce",
        "scala_library_sources": "a32ccfac851adeb094a31134af1034d0ba026512931433cba86d5dd12d91f1ff",
        "scala_reflect": "6ba385b450a6311a15c918cf8688b9af9327c6104f0ecbd35933cfcd3095fe04",
        "scala_reflect_sources": "4d4adbc4f5f6be87ec555635dd40926bf71c6d638a06d59d929de04386099063",
    }

def extract_major_version(scala_version):
    """Return major Scala version given a full version, e.g. "2.11.11" -> "2.11" """
    return scala_version[:scala_version.find(".", 2)]

def extract_major_version_underscore(scala_version):
    """Return major Scala version with underscore given a full version,
    e.g. "2.11.11" -> "2_11" """
    return extract_major_version(scala_version).replace(".", "_")

def default_scala_major_version():
    return extract_major_version(default_scala_version())

def scala_mvn_artifact(
        artifact,
        major_scala_version = default_scala_major_version()):
    """Add scala version to maven artifact"""
    gav = artifact.split(":")
    groupid = gav[0]
    artifactid = gav[1]
    version = gav[2]
    return "%s:%s_%s:%s" % (groupid, artifactid, major_scala_version, version)

def new_scala_default_repository(
        scala_version,
        scala_version_jar_shas,
        maven_servers,
        fetch_sources):
    _scala_maven_import_external(
        name = "io_bazel_rules_scala_scala_library",
        artifact = "org.scala-lang:scala-library:{}".format(scala_version),
        jar_sha256 = scala_version_jar_shas["scala_library"],
        srcjar_sha256 = scala_version_jar_shas["scala_library_sources"],
        fetch_sources = fetch_sources,
        licenses = ["notice"],
        server_urls = maven_servers,
    )
    _scala_maven_import_external(
        name = "io_bazel_rules_scala_scala_compiler",
        artifact = "org.scala-lang:scala-compiler:{}".format(scala_version),
        jar_sha256 = scala_version_jar_shas["scala_compiler"],
        srcjar_sha256 = scala_version_jar_shas["scala_compiler_sources"],
        fetch_sources = fetch_sources,
        licenses = ["notice"],
        server_urls = maven_servers,
    )
    _scala_maven_import_external(
        name = "io_bazel_rules_scala_scala_reflect",
        artifact = "org.scala-lang:scala-reflect:{}".format(scala_version),
        jar_sha256 = scala_version_jar_shas["scala_reflect"],
        srcjar_sha256 = scala_version_jar_shas["scala_reflect_sources"],
        fetch_sources = fetch_sources,
        licenses = ["notice"],
        server_urls = maven_servers,
    )
