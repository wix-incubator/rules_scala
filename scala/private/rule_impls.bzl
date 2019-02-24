# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rules for supporting the Scala language."""

load(
    "@io_bazel_rules_scala//scala:providers.bzl",
    "create_scala_provider",
    _ScalacProvider = "ScalacProvider",
)
load(
    ":common.bzl",
    "add_labels_of_jars_to",
    "collect_jars",
    "collect_srcjars",
    "create_java_provider",
    "not_sources_jar",
    "write_manifest",
)
load("@io_bazel_rules_scala//scala:jars_to_labels.bzl", "JarsToLabelsInfo")

_java_extension = ".java"
_scala_extension = ".scala"
_srcjar_extension = ".srcjar"

def _adjust_resources_path_by_strip_prefix(path, resource_strip_prefix):
    if not path.startswith(resource_strip_prefix):
        fail("Resource file %s is not under the specified prefix to strip" % path)

    clean_path = path[len(resource_strip_prefix):]
    return resource_strip_prefix, clean_path

def _adjust_resources_path_by_default_prefixes(path):
    #  Here we are looking to find out the offset of this resource inside
    #  any resources folder. We want to return the root to the resources folder
    #  and then the sub path inside it
    dir_1, dir_2, rel_path = path.partition("resources")
    if rel_path:
        return dir_1 + dir_2, rel_path

    #  The same as the above but just looking for java
    (dir_1, dir_2, rel_path) = path.partition("java")
    if rel_path:
        return dir_1 + dir_2, rel_path

    return "", path

def _adjust_resources_path(path, resource_strip_prefix):
    if resource_strip_prefix:
        return _adjust_resources_path_by_strip_prefix(path, resource_strip_prefix)
    else:
        return _adjust_resources_path_by_default_prefixes(path)

def _add_resources_cmd(ctx):
    res_cmd = []
    for f in ctx.files.resources:
        c_dir, res_path = _adjust_resources_path(
            f.short_path,
            ctx.attr.resource_strip_prefix,
        )
        target_path = res_path
        if target_path[0] == "/":
            target_path = target_path[1:]
        line = "{target_path}={c_dir}{res_path}\n".format(
            res_path = res_path,
            target_path = target_path,
            c_dir = c_dir,
        )
        res_cmd.extend([line])
    return "".join(res_cmd)

def _build_nosrc_jar(ctx):
    resources = _add_resources_cmd(ctx)
    ijar_cmd = ""

    # this ensures the file is not empty
    resources += "META-INF/MANIFEST.MF=%s\n" % ctx.outputs.manifest.path

    zipper_arg_path = ctx.actions.declare_file("%s_zipper_args" % ctx.label.name)
    ctx.actions.write(zipper_arg_path, resources)
    cmd = """
rm -f {jar_output}
{zipper} c {jar_output} @{path}
# ensures that empty src targets still emit a statsfile
touch {statsfile}
""" + ijar_cmd

    cmd = cmd.format(
        path = zipper_arg_path.path,
        jar_output = ctx.outputs.jar.path,
        zipper = ctx.executable._zipper.path,
        statsfile = ctx.outputs.statsfile.path,
    )

    outs = [ctx.outputs.jar, ctx.outputs.statsfile]
    inputs = ctx.files.resources + [ctx.outputs.manifest]

    ctx.actions.run_shell(
        inputs = inputs,
        tools = [ctx.executable._zipper, zipper_arg_path],
        outputs = outs,
        command = cmd,
        progress_message = "scala %s" % ctx.label,
        arguments = [],
    )

def _collect_plugin_paths(plugins):
    paths = []
    for p in plugins:
        if hasattr(p, "path"):
            paths.append(p)
        elif hasattr(p, "scala"):
            paths.append(p.scala.outputs.jar)
        elif hasattr(p, "java"):
            paths.extend([j.class_jar for j in p.java.outputs.jars])
            # support http_file pointed at a jar. http_jar uses ijar,
            # which breaks scala macros

        elif hasattr(p, "files"):
            paths.extend([f for f in p.files if not_sources_jar(f.basename)])
    return depset(paths)

def _expand_location(ctx, flags):
    return [ctx.expand_location(f, ctx.attr.data) for f in flags]

def _join_path(args, sep = ","):
    return sep.join([f.path for f in args])

def compile_scala(
        ctx,
        target_label,
        output,
        manifest,
        statsfile,
        sources,
        cjars,
        all_srcjars,
        transitive_compile_jars,
        plugins,
        resource_strip_prefix,
        resources,
        resource_jars,
        labels,
        in_scalacopts,
        print_compile_time,
        expect_java_output,
        scalac_jvm_flags,
        scalac,
        unused_dependency_checker_mode = "off",
        unused_dependency_checker_ignored_targets = []):
    # look for any plugins:
    plugins = _collect_plugin_paths(plugins)
    internal_plugin_jars = []
    dependency_analyzer_mode = "off"
    compiler_classpath_jars = cjars
    optional_scalac_args = ""
    classpath_resources = []
    if (hasattr(ctx.files, "classpath_resources")):
        classpath_resources = ctx.files.classpath_resources

    if is_dependency_analyzer_on(ctx):
        # "off" mode is used as a feature toggle, that preserves original behaviour
        dependency_analyzer_mode = ctx.fragments.java.strict_java_deps
        dep_plugin = ctx.attr._dependency_analyzer_plugin
        plugins = depset(transitive = [plugins, dep_plugin.files])
        internal_plugin_jars = ctx.files._dependency_analyzer_plugin
        compiler_classpath_jars = transitive_compile_jars

        direct_jars = _join_path(cjars.to_list())

        transitive_cjars_list = transitive_compile_jars.to_list()
        indirect_jars = _join_path(transitive_cjars_list)
        indirect_targets = ",".join([labels[j.path] for j in transitive_cjars_list])

        current_target = str(target_label)

        optional_scalac_args = """
DirectJars: {direct_jars}
IndirectJars: {indirect_jars}
IndirectTargets: {indirect_targets}
CurrentTarget: {current_target}
        """.format(
            direct_jars = direct_jars,
            indirect_jars = indirect_jars,
            indirect_targets = indirect_targets,
            current_target = current_target,
        )

    elif unused_dependency_checker_mode != "off":
        unused_dependency_plugin = ctx.attr._unused_dependency_checker_plugin
        plugins = depset(transitive = [plugins, unused_dependency_plugin.files])
        internal_plugin_jars = ctx.files._unused_dependency_checker_plugin

        cjars_list = cjars.to_list()
        direct_jars = _join_path(cjars_list)
        direct_targets = ",".join([labels[j.path] for j in cjars_list])

        ignored_targets = ",".join(unused_dependency_checker_ignored_targets)

        current_target = str(target_label)

        optional_scalac_args = """
DirectJars: {direct_jars}
DirectTargets: {direct_targets}
IgnoredTargets: {ignored_targets}
CurrentTarget: {current_target}
        """.format(
            direct_jars = direct_jars,
            direct_targets = direct_targets,
            ignored_targets = ignored_targets,
            current_target = current_target,
        )
    if is_dependency_analyzer_off(ctx) and not _is_plus_one_deps_off(ctx):
       compiler_classpath_jars = transitive_compile_jars

    plugins_list = plugins.to_list()
    plugin_arg = _join_path(plugins_list)

    separator = ctx.configuration.host_path_separator
    compiler_classpath = _join_path(compiler_classpath_jars.to_list(), separator)

    toolchain = ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"]
    scalacopts = toolchain.scalacopts + in_scalacopts

    scalac_args = """
Classpath: {cp}
ClasspathResourceSrcs: {classpath_resource_src}
Files: {files}
JarOutput: {out}
Manifest: {manifest}
Plugins: {plugin_arg}
PrintCompileTime: {print_compile_time}
ExpectJavaOutput: {expect_java_output}
ResourceDests: {resource_dest}
ResourceJars: {resource_jars}
ResourceSrcs: {resource_src}
ResourceShortPaths: {resource_short_paths}
ResourceStripPrefix: {resource_strip_prefix}
ScalacOpts: {scala_opts}
SourceJars: {srcjars}
DependencyAnalyzerMode: {dependency_analyzer_mode}
UnusedDependencyCheckerMode: {unused_dependency_checker_mode}
StatsfileOutput: {statsfile_output}
""".format(
        out = output.path,
        manifest = manifest.path,
        scala_opts = ",".join(scalacopts),
        print_compile_time = print_compile_time,
        expect_java_output = expect_java_output,
        plugin_arg = plugin_arg,
        cp = compiler_classpath,
        classpath_resource_src = _join_path(classpath_resources),
        files = _join_path(sources),
        srcjars = _join_path(all_srcjars.to_list()),
        # the resource paths need to be aligned in order
        resource_src = ",".join([f.path for f in resources]),
        resource_short_paths = ",".join([f.short_path for f in resources]),
        resource_dest = ",".join([
            _adjust_resources_path_by_default_prefixes(f.short_path)[1]
            for f in resources
        ]),
        resource_strip_prefix = resource_strip_prefix,
        resource_jars = _join_path(resource_jars),
        dependency_analyzer_mode = dependency_analyzer_mode,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        statsfile_output = statsfile.path,
    )

    argfile = ctx.actions.declare_file(
        "%s_scalac_worker_input" % target_label.name,
        sibling = output,
    )

    ctx.actions.write(
        output = argfile,
        content = scalac_args + optional_scalac_args,
    )

    scalac_inputs, _, scalac_input_manifests = ctx.resolve_command(
        tools = [scalac],
    )

    outs = [output, statsfile]
    ins = (
        compiler_classpath_jars.to_list() + all_srcjars.to_list() + list(sources) +
        plugins_list + internal_plugin_jars + classpath_resources + resources +
        resource_jars + [manifest, argfile] + scalac_inputs
    )

    ctx.actions.run(
        inputs = ins,
        outputs = outs,
        executable = scalac.files_to_run.executable,
        input_manifests = scalac_input_manifests,
        mnemonic = "Scalac",
        progress_message = "scala %s" % target_label,
        execution_requirements = {"supports-workers": "1"},
        #  when we run with a worker, the `@argfile.path` is removed and passed
        #  line by line as arguments in the protobuf. In that case,
        #  the rest of the arguments are passed to the process that
        #  starts up and stays resident.

        # In either case (worker or not), they will be jvm flags which will
        # be correctly handled since the executable is a jvm app that will
        # consume the flags on startup.
        arguments = [
            "--jvm_flag=%s" % f
            for f in _expand_location(ctx, scalac_jvm_flags)
        ] + ["@" + argfile.path],
    )

def _interim_java_provider_for_java_compilation(scala_output):
    return java_common.create_provider(
        use_ijar = False,
        compile_time_jars = [scala_output],
        runtime_jars = [],
    )

def _scalac_provider(ctx):
    return ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].scalac_provider_attr[_ScalacProvider]

def try_to_compile_java_jar(
        ctx,
        scala_output,
        all_srcjars,
        java_srcs,
        implicit_junit_deps_needed_for_java_compilation):
    if not java_srcs and (not (all_srcjars and ctx.attr.expect_java_output)):
        return False

    providers_of_dependencies = collect_java_providers_of(ctx.attr.deps)
    providers_of_dependencies += collect_java_providers_of(
        implicit_junit_deps_needed_for_java_compilation,
    )
    providers_of_dependencies += collect_java_providers_of(
        _scalac_provider(ctx).default_classpath,
    )
    scala_sources_java_provider = _interim_java_provider_for_java_compilation(
        scala_output,
    )
    providers_of_dependencies += [scala_sources_java_provider]

    full_java_jar = ctx.actions.declare_file(ctx.label.name + "_java.jar")

    provider = java_common.compile(
        ctx,
        source_jars = all_srcjars.to_list(),
        source_files = java_srcs,
        output = full_java_jar,
        javac_opts = _expand_location(
            ctx,
            ctx.attr.javacopts + ctx.attr.javac_jvm_flags +
            java_common.default_javac_opts(
                ctx,
                java_toolchain_attr = "_java_toolchain",
            ),
        ),
        deps = providers_of_dependencies,
        #exports can be empty since the manually created provider exposes exports
        #needs to be empty since we want the provider.compile_jars to only contain the sources ijar
        #workaround until https://github.com/bazelbuild/bazel/issues/3528 is resolved
        exports = [],
        java_toolchain = ctx.attr._java_toolchain,
        host_javabase = ctx.attr._host_javabase,
        strict_deps = ctx.fragments.java.strict_java_deps,
    )
    return struct(
        jar = full_java_jar,
        ijar = provider.compile_jars.to_list().pop(),
        source_jars = provider.source_jars
    )

def collect_java_providers_of(deps):
    providers = []
    for dep in deps:
        if JavaInfo in dep:
            providers.append(dep[JavaInfo])
    return providers

def _compile_or_empty(
        ctx,
        manifest,
        jars,
        srcjars,
        buildijar,
        transitive_compile_jars,
        jars2labels,
        implicit_junit_deps_needed_for_java_compilation,
        unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets):
    # We assume that if a srcjar is present, it is not empty
    if len(ctx.files.srcs) + len(srcjars.to_list()) == 0:
        _build_nosrc_jar(ctx)

        #  no need to build ijar when empty
        return struct(
            ijar = ctx.outputs.jar,
            class_jar = ctx.outputs.jar,
            java_jar = False,
            full_jars = [ctx.outputs.jar],
            ijars = [ctx.outputs.jar],
            source_jars = [],
        )
    else:
        in_srcjars = [
            f
            for f in ctx.files.srcs
            if f.basename.endswith(_srcjar_extension)
        ]
        all_srcjars = depset(in_srcjars, transitive = [srcjars])

        java_srcs = [
            f
            for f in ctx.files.srcs
            if f.basename.endswith(_java_extension)
        ]

        # We are not able to verify whether dependencies are used when compiling java sources
        # Thus we disable unused dependency checking when java sources are found
        if len(java_srcs) != 0:
            unused_dependency_checker_mode = "off"

        sources = [
            f
            for f in ctx.files.srcs
            if f.basename.endswith(_scala_extension)
        ] + java_srcs
        compile_scala(
            ctx,
            ctx.label,
            ctx.outputs.jar,
            manifest,
            ctx.outputs.statsfile,
            sources,
            jars,
            all_srcjars,
            transitive_compile_jars,
            ctx.attr.plugins,
            ctx.attr.resource_strip_prefix,
            ctx.files.resources,
            ctx.files.resource_jars,
            jars2labels,
            ctx.attr.scalacopts,
            ctx.attr.print_compile_time,
            ctx.attr.expect_java_output,
            ctx.attr.scalac_jvm_flags,
            ctx.attr._scalac,
            unused_dependency_checker_mode = unused_dependency_checker_mode,
            unused_dependency_checker_ignored_targets =
                unused_dependency_checker_ignored_targets,
        )

        # build ijar if needed
        if buildijar:
            ijar = java_common.run_ijar(
                ctx.actions,
                jar = ctx.outputs.jar,
                target_label = ctx.label,
                java_toolchain = ctx.attr._java_toolchain,
            )
        else:
            #  macro code needs to be available at compile-time,
            #  so set ijar == jar
            ijar = ctx.outputs.jar

        # compile the java now
        java_jar = try_to_compile_java_jar(
            ctx,
            ijar,
            all_srcjars,
            java_srcs,
            implicit_junit_deps_needed_for_java_compilation,
        )

        full_jars = [ctx.outputs.jar]
        ijars = [ijar]
        source_jars = []
        if java_jar:
            full_jars += [java_jar.jar]
            ijars += [java_jar.ijar]
            source_jars += java_jar.source_jars
        return struct(
            ijar = ijar,
            class_jar = ctx.outputs.jar,
            java_jar = java_jar,
            full_jars = full_jars,
            ijars = ijars,
            source_jars = source_jars,
        )

def _build_deployable(ctx, jars_list):
    # This calls bazels singlejar utility.
    # For a full list of available command line options see:
    # https://github.com/bazelbuild/bazel/blob/master/src/java_tools/singlejar/java/com/google/devtools/build/singlejar/SingleJar.java#L311
    # Use --compression to reduce size of deploy jars.
    args = ["--compression", "--normalize", "--sources"]
    args.extend([j.path for j in jars_list])
    if getattr(ctx.attr, "main_class", ""):
        args.extend(["--main_class", ctx.attr.main_class])
    args.extend(["--output", ctx.outputs.deploy_jar.path])
    ctx.actions.run(
        inputs = jars_list,
        outputs = [ctx.outputs.deploy_jar],
        executable = ctx.executable._singlejar,
        mnemonic = "ScalaDeployJar",
        progress_message = "scala deployable %s" % ctx.label,
        arguments = args,
    )

def _path_is_absolute(path):
    # Returns true for absolute path in Linux/Mac (i.e., '/') or Windows (i.e.,
    # 'X:\' or 'X:/' where 'X' is a letter), false otherwise.
    if len(path) >= 1 and path[0] == "/":
        return True
    if len(path) >= 3 and \
       path[0].isalpha() and \
       path[1] == ":" and \
       (path[2] == "/" or path[2] == "\\"):
        return True

    return False

def _runfiles_root(ctx):
    return "${TEST_SRCDIR}/%s" % ctx.workspace_name

def _write_java_wrapper(ctx, args = "", wrapper_preamble = ""):
    """This creates a wrapper that sets up the correct path
         to stand in for the java command."""

    java_path = str(ctx.attr._java_runtime[java_common.JavaRuntimeInfo]
        .java_executable_runfiles_path)
    if _path_is_absolute(java_path):
        javabin = java_path
    else:
        runfiles_root = _runfiles_root(ctx)
        javabin = "%s/%s" % (runfiles_root, java_path)

    exec_str = ""
    if wrapper_preamble == "":
        exec_str = "exec "

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper.sh")
    ctx.actions.write(
        output = wrapper,
        content = """#!/usr/bin/env bash
{preamble}
rm -rf {runfiles_root}/target/test-classes
mkdir -p {runfiles_root}/target/test-classes

DEFAULT_JAVABIN={javabin}
JAVA_EXEC_TO_USE=${{REAL_EXTERNAL_JAVA_BIN:-$DEFAULT_JAVABIN}}
{exec_str}$JAVA_EXEC_TO_USE "$@" {args}
""".format(
            preamble = wrapper_preamble,
            exec_str = exec_str,
            javabin = javabin,
            args = args,
            runfiles_root = _runfiles_root(ctx)
        ),
        is_executable = True,
    )
    return wrapper

def _write_executable(ctx, rjars, main_class, jvm_flags, wrapper):
    template = ctx.attr._java_stub_template.files.to_list()[0]

    # RUNPATH is defined here:
    # https://github.com/bazelbuild/bazel/blob/0.4.5/src/main/java/com/google/devtools/build/lib/bazel/rules/java/java_stub_template.txt#L227
    classpath = ":".join(
        ["${RUNPATH}%s" % (j.short_path) for j in rjars.to_list()],
    )
    if ctx.attr.testonly:
             classpath = ":".join(["%s" % (j.short_path) for j in rjars])
             classpath = "target/test-classes:%s" % classpath
    jvm_flags = " ".join(
        [ctx.expand_location(f, ctx.attr.data) for f in jvm_flags],
    )
    ctx.actions.expand_template(
        template = template,
        output = ctx.outputs.executable,
        substitutions = {
            "%classpath%": classpath,
            "%java_start_class%": main_class,
            "%javabin%": "export REAL_EXTERNAL_JAVA_BIN=${JAVABIN};JAVABIN=%s/%s" % (
                _runfiles_root(ctx),
                wrapper.short_path,
            ),
            "%jvm_flags%": jvm_flags,
            "%needs_runfiles%": "",
            "%runfiles_manifest_only%": "",
            "%set_jacoco_metadata%": "",
            "%set_jacoco_main_class%": "",
            "%set_jacoco_java_runfiles_root%": "",
            "%workspace_prefix%": ctx.workspace_name + "/",
        },
        is_executable = True,
    )

def _collect_runtime_jars(dep_targets):
    runtime_jars = []

    for dep_target in dep_targets:
        runtime_jars.append(dep_target[JavaInfo].transitive_runtime_jars)

    return runtime_jars

def is_dependency_analyzer_on(ctx):
    if (hasattr(ctx.attr, "_dependency_analyzer_plugin") and
        # when the strict deps FT is removed the "default" check
        # will be removed since "default" will mean it's turned on
        ctx.fragments.java.strict_java_deps != "default" and
        ctx.fragments.java.strict_java_deps != "off"):
        return True

def is_dependency_analyzer_off(ctx):
    return not is_dependency_analyzer_on(ctx)

def _is_plus_one_deps_off(ctx):
    return ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].plus_one_deps_mode == "off"

# Extract very common code out from dependency analysis into single place
# automatically adds dependency on scala-library and scala-reflect
# collects jars from deps, runtime jars from runtime_deps, and
def _collect_jars_from_common_ctx(
        ctx,
        base_classpath,
        extra_deps = [],
        extra_runtime_deps = [],
        unused_dependency_checker_is_off = True):
    dependency_analyzer_is_off = is_dependency_analyzer_off(ctx)

    deps_jars = collect_jars(
        ctx.attr.deps + extra_deps + base_classpath,
        dependency_analyzer_is_off,
        unused_dependency_checker_is_off,
        _is_plus_one_deps_off(ctx),
    )

    (
        cjars,
        transitive_rjars,
        jars2labels,
        transitive_compile_jars,
    ) = (
        deps_jars.compile_jars,
        deps_jars.transitive_runtime_jars,
        deps_jars.jars2labels,
        deps_jars.transitive_compile_jars,
    )

    transitive_rjars = depset(
        transitive = [transitive_rjars] +
                     _collect_runtime_jars(ctx.attr.runtime_deps + extra_runtime_deps),
    )

    return struct(
        compile_jars = cjars,
        transitive_runtime_jars = transitive_rjars,
        jars2labels = jars2labels,
        transitive_compile_jars = transitive_compile_jars,
    )

def _lib(
        ctx,
        base_classpath,
        non_macro_lib,
        unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets):
    # Build up information from dependency-like attributes

    # This will be used to pick up srcjars from non-scala library
    # targets (like thrift code generation)
    srcjars = collect_srcjars(ctx.attr.deps)

    unused_dependency_checker_is_off = unused_dependency_checker_mode == "off"
    jars = _collect_jars_from_common_ctx(
        ctx,
        base_classpath,
        unused_dependency_checker_is_off = unused_dependency_checker_is_off,
    )

    (cjars, transitive_rjars) = (jars.compile_jars, jars.transitive_runtime_jars)

    write_manifest(ctx)
    outputs = _compile_or_empty(
        ctx,
        ctx.outputs.manifest,
        cjars,
        srcjars,
        non_macro_lib,
        jars.transitive_compile_jars,
        jars.jars2labels.jars_to_labels,
        [],
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets = [
            target.label
            for target in base_classpath + ctx.attr.exports +
                          unused_dependency_checker_ignored_targets
        ],
    )

    transitive_rjars = depset(outputs.full_jars, transitive = [transitive_rjars])

    _build_deployable(ctx, transitive_rjars.to_list())

    # Using transitive_files since transitive_rjars a depset and avoiding linearization
    runfiles = ctx.runfiles(
        transitive_files = transitive_rjars,
        collect_data = True,
    )

    # Add information from exports (is key that AFTER all build actions/runfiles analysis)
    # Since after, will not show up in deploy_jar or old jars runfiles
    # Notice that compile_jars is intentionally transitive for exports
    exports_jars = collect_jars(ctx.attr.exports)
    transitive_rjars = depset(
        transitive = [transitive_rjars, exports_jars.transitive_runtime_jars],
    )

    source_jars = _pack_source_jars(ctx) + outputs.source_jars

    scalaattr = create_scala_provider(
        ijar = outputs.ijar,
        class_jar = outputs.class_jar,
        compile_jars = depset(
            outputs.ijars,
            transitive = [exports_jars.compile_jars],
        ),
        transitive_runtime_jars = transitive_rjars,
        deploy_jar = ctx.outputs.deploy_jar,
        full_jars = outputs.full_jars,
        statsfile = ctx.outputs.statsfile,
        source_jars = source_jars,
    )

    java_provider = create_java_provider(scalaattr, jars.transitive_compile_jars)

    return struct(
        files = depset([ctx.outputs.jar] + outputs.full_jars),  # Here is the default output
        scala = scalaattr,
        providers = [java_provider, jars.jars2labels],
        runfiles = runfiles,
        jars_to_labels = jars.jars2labels,
    )

def get_unused_dependency_checker_mode(ctx):
    if ctx.attr.unused_dependency_checker_mode:
        return ctx.attr.unused_dependency_checker_mode
    else:
        return ctx.toolchains["@io_bazel_rules_scala//scala:toolchain_type"].unused_dependency_checker_mode

def scala_library_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    return _lib(
        ctx,
        scalac_provider.default_classpath,
        True,
        unused_dependency_checker_mode,
        ctx.attr.unused_dependency_checker_ignored_targets,
    )

def scala_library_for_plugin_bootstrapping_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    return _lib(
        ctx,
        scalac_provider.default_classpath,
        True,
        unused_dependency_checker_mode = "off",
        unused_dependency_checker_ignored_targets = [],
    )

def scala_macro_library_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    return _lib(
        ctx,
        scalac_provider.default_macro_classpath,
        False,  # don't build the ijar for macros
        unused_dependency_checker_mode,
        ctx.attr.unused_dependency_checker_ignored_targets,
    )

# Common code shared by all scala binary implementations.
def _scala_binary_common(
        ctx,
        cjars,
        rjars,
        transitive_compile_time_jars,
        jars2labels,
        java_wrapper,
        unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets,
        implicit_junit_deps_needed_for_java_compilation = []):
    write_manifest(ctx)
    outputs = _compile_or_empty(
        ctx,
        ctx.outputs.manifest,
        cjars,
        depset(),
        False,
        transitive_compile_time_jars,
        jars2labels.jars_to_labels,
        implicit_junit_deps_needed_for_java_compilation,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets =
            unused_dependency_checker_ignored_targets,
    )  # no need to build an ijar for an executable
    rjars = depset(outputs.full_jars, transitive = [rjars])

    _build_deployable(ctx, rjars.to_list())

    runfiles = ctx.runfiles(
        transitive_files = depset(
            [ctx.outputs.executable, java_wrapper] + ctx.files._java_runtime,
            transitive = [rjars],
        ),
        collect_data = True,
    )

    source_jars = _pack_source_jars(ctx) + outputs.source_jars

    scalaattr = create_scala_provider(
        ijar = outputs.class_jar,  # we aren't using ijar here
        class_jar = outputs.class_jar,
        compile_jars = depset(outputs.ijars),
        transitive_runtime_jars = rjars,
        deploy_jar = ctx.outputs.deploy_jar,
        full_jars = outputs.full_jars,
        statsfile = ctx.outputs.statsfile,
        source_jars = source_jars,
    )

    java_provider = create_java_provider(scalaattr, transitive_compile_time_jars)

    return struct(
        files = depset([ctx.outputs.executable, ctx.outputs.jar]),
        providers = [java_provider, jars2labels],
        scala = scalaattr,
        transitive_rjars =
            rjars,  #calling rules need this for the classpath in the launcher
        runfiles = runfiles,
    )

def _pack_source_jars(ctx):
  source_jars = []

  # collect .scala sources and pack a source jar for Scala
  scala_sources = [
      f for f in ctx.files.srcs
      if f.basename.endswith(_scala_extension)
  ]

  # collect .srcjar files and pack them with the scala sources
  bundled_source_jars = [
      f for f in ctx.files.srcs
      if f.basename.endswith(_srcjar_extension)
  ]
  scala_source_jar = java_common.pack_sources(
      ctx.actions,
      output_jar = ctx.outputs.jar,
      sources = scala_sources,
      source_jars = bundled_source_jars,
      java_toolchain = ctx.attr._java_toolchain,
      host_javabase = ctx.attr._host_javabase
  )
  if scala_source_jar:
    source_jars.append(scala_source_jar)

  return source_jars

def scala_binary_impl(ctx):
    scalac_provider = _scalac_provider(ctx)
    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    unused_dependency_checker_is_off = unused_dependency_checker_mode == "off"

    jars = _collect_jars_from_common_ctx(
        ctx,
        scalac_provider.default_classpath,
        unused_dependency_checker_is_off = unused_dependency_checker_is_off,
    )
    (cjars, transitive_rjars) = (jars.compile_jars, jars.transitive_runtime_jars)

    wrapper = _write_java_wrapper(ctx, "", "")
    out = _scala_binary_common(
        ctx,
        cjars,
        transitive_rjars,
        jars.transitive_compile_jars,
        jars.jars2labels,
        wrapper,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets = [
            target.label
            for target in scalac_provider.default_classpath +
                          ctx.attr.unused_dependency_checker_ignored_targets
        ],
    )
    _write_executable(
        ctx = ctx,
        rjars = out.transitive_rjars,
        main_class = ctx.attr.main_class,
        jvm_flags = ctx.attr.jvm_flags,
        wrapper = wrapper,
    )
    return out

def scala_repl_impl(ctx):
    scalac_provider = _scalac_provider(ctx)

    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    unused_dependency_checker_is_off = unused_dependency_checker_mode == "off"

    # need scala-compiler for MainGenericRunner below
    jars = _collect_jars_from_common_ctx(
        ctx,
        scalac_provider.default_repl_classpath,
        unused_dependency_checker_is_off = unused_dependency_checker_is_off,
    )
    (cjars, transitive_rjars) = (jars.compile_jars, jars.transitive_runtime_jars)

    args = " ".join(ctx.attr.scalacopts)
    wrapper = _write_java_wrapper(
        ctx,
        args,
        wrapper_preamble = """
# save stty like in bin/scala
saved_stty=$(stty -g 2>/dev/null)
if [[ ! $? ]]; then
  saved_stty=""
fi
function finish() {
  if [[ "$saved_stty" != "" ]]; then
    stty $saved_stty
    saved_stty=""
  fi
}
trap finish EXIT
""",
    )

    out = _scala_binary_common(
        ctx,
        cjars,
        transitive_rjars,
        jars.transitive_compile_jars,
        jars.jars2labels,
        wrapper,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets = [
            target.label
            for target in scalac_provider.default_repl_classpath +
                          ctx.attr.unused_dependency_checker_ignored_targets
        ],
    )
    _write_executable(
        ctx = ctx,
        rjars = out.transitive_rjars,
        main_class = "scala.tools.nsc.MainGenericRunner",
        jvm_flags = ["-Dscala.usejavacp=true"] + ctx.attr.jvm_flags,
        wrapper = wrapper,
    )

    return out

def _scala_test_flags(ctx):
    # output report test duration
    flags = "-oD"
    if ctx.attr.full_stacktraces:
        flags += "F"
    else:
        flags += "S"
    if not ctx.attr.colors:
        flags += "W"
    return flags

def scala_test_impl(ctx):
    if len(ctx.attr.suites) != 0:
        print("suites attribute is deprecated. All scalatest test suites are run")

    scalac_provider = _scalac_provider(ctx)

    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    unused_dependency_checker_ignored_targets = [
        target.label
        for target in scalac_provider.default_classpath +
                      ctx.attr.unused_dependency_checker_ignored_targets
    ]
    unused_dependency_checker_is_off = unused_dependency_checker_mode == "off"

    scalatest_base_classpath = scalac_provider.default_classpath + [ctx.attr._scalatest]
    jars = _collect_jars_from_common_ctx(
        ctx,
        scalatest_base_classpath,
        extra_runtime_deps = [
            ctx.attr._scalatest_reporter,
            ctx.attr._scalatest_runner,
        ],
        unused_dependency_checker_is_off = unused_dependency_checker_is_off,
    )
    (
        cjars,
        transitive_rjars,
        transitive_compile_jars,
        jars_to_labels,
    ) = (
        jars.compile_jars,
        jars.transitive_runtime_jars,
        jars.transitive_compile_jars,
        jars.jars2labels,
    )

    args = " ".join([
        "-R \"{path}\"".format(path = ctx.outputs.jar.short_path),
        _scala_test_flags(ctx),
        "-C io.bazel.rules.scala.JUnitXmlReporter ",
    ])

    # main_class almost has to be "org.scalatest.tools.Runner" due to args....
    wrapper = _write_java_wrapper(ctx, args, "")
    out = _scala_binary_common(
        ctx,
        cjars,
        transitive_rjars,
        transitive_compile_jars,
        jars_to_labels,
        wrapper,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets =
            unused_dependency_checker_ignored_targets,
    )
    _write_executable(
        ctx = ctx,
        rjars = out.transitive_rjars,
        main_class = ctx.attr.main_class,
        jvm_flags = ctx.attr.jvm_flags,
        wrapper = wrapper,
    )
    return out

def _gen_test_suite_flags_based_on_prefixes_and_suffixes(ctx, archives):
    return struct(
        testSuiteFlag = "-Dbazel.test_suite=%s" % ctx.attr.suite_class,
        archiveFlag = "-Dbazel.discover.classes.archives.file.paths=%s" %
                      archives,
        prefixesFlag = "-Dbazel.discover.classes.prefixes=%s" % ",".join(
            ctx.attr.prefixes,
        ),
        suffixesFlag = "-Dbazel.discover.classes.suffixes=%s" % ",".join(
            ctx.attr.suffixes,
        ),
        printFlag = "-Dbazel.discover.classes.print.discovered=%s" %
                    ctx.attr.print_discovered_classes,
    )

def _serialize_archives_short_path(archives):
    archives_short_path = ""
    for archive in archives:
        archives_short_path += archive.short_path + ","
    return archives_short_path[:-1]  #remove redundant comma

def _get_test_archive_jars(ctx, test_archives):
    flattened_list = []
    for archive in test_archives:
        # because we (rules_scala) use the legacy JavaInfo (java_common.create_provider)
        # runtime_output_jars contains more jars than needed
        if hasattr(archive, "scala"):
            jars = [jar.class_jar for jar in archive.scala.outputs.jars]
        else:
            jars = archive[JavaInfo].runtime_output_jars
        flattened_list.extend(jars)
    return flattened_list

def scala_junit_test_impl(ctx):
    if (not (ctx.attr.prefixes) and not (ctx.attr.suffixes)):
        fail(
            "Setting at least one of the attributes ('prefixes','suffixes') is required",
        )
    scalac_provider = _scalac_provider(ctx)

    unused_dependency_checker_mode = get_unused_dependency_checker_mode(ctx)
    unused_dependency_checker_ignored_targets = [
        target.label
        for target in scalac_provider.default_classpath +
                      ctx.attr.unused_dependency_checker_ignored_targets
    ] + [
        ctx.attr._junit.label,
        ctx.attr._hamcrest.label,
        ctx.attr.suite_label.label,
        ctx.attr._bazel_test_runner.label,
    ]
    unused_dependency_checker_is_off = unused_dependency_checker_mode == "off"

    jars = _collect_jars_from_common_ctx(
        ctx,
        scalac_provider.default_classpath,
        extra_deps = [
            ctx.attr._junit,
            ctx.attr._hamcrest,
            ctx.attr.suite_label,
            ctx.attr._bazel_test_runner,
        ],
        unused_dependency_checker_is_off = unused_dependency_checker_is_off,
    )
    (cjars, transitive_rjars) = (jars.compile_jars, jars.transitive_runtime_jars)
    implicit_junit_deps_needed_for_java_compilation = [
        ctx.attr._junit,
        ctx.attr._hamcrest,
    ]

    wrapper = _write_java_wrapper(ctx, "", "")
    out = _scala_binary_common(
        ctx,
        cjars,
        transitive_rjars,
        jars.transitive_compile_jars,
        jars.jars2labels,
        wrapper,
        implicit_junit_deps_needed_for_java_compilation =
            implicit_junit_deps_needed_for_java_compilation,
        unused_dependency_checker_mode = unused_dependency_checker_mode,
        unused_dependency_checker_ignored_targets =
            unused_dependency_checker_ignored_targets,
    )

    if ctx.attr.tests_from:
        archives = _get_test_archive_jars(ctx, ctx.attr.tests_from)
    else:
        archives = [archive.class_jar for archive in out.scala.outputs.jars]

    serialized_archives = _serialize_archives_short_path(archives)
    test_suite = _gen_test_suite_flags_based_on_prefixes_and_suffixes(
        ctx,
        serialized_archives,
    )
    launcherJvmFlags = [
        "-ea",
        test_suite.archiveFlag,
        test_suite.prefixesFlag,
        test_suite.suffixesFlag,
        test_suite.printFlag,
        test_suite.testSuiteFlag,
    ]
    _write_executable(
        ctx = ctx,
        rjars = out.transitive_rjars,
        main_class = "com.google.testing.junit.runner.BazelTestRunner",
        jvm_flags = launcherJvmFlags + ctx.attr.jvm_flags,
        wrapper = wrapper,
    )

    return out
