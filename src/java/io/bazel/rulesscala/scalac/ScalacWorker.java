package io.bazel.rulesscala.scalac;

import static java.io.File.pathSeparator;

import io.bazel.rulesscala.io_utils.StreamCopy;
import io.bazel.rulesscala.jar.JarCreator;
import io.bazel.rulesscala.worker.Worker;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import scala.tools.nsc.reporters.ConsoleReporter;

class ScalacWorker implements Worker.Interface {

  private static final boolean isWindows =
      System.getProperty("os.name").toLowerCase().contains("windows");

  public static void main(String[] args) throws Exception {
    Worker.workerMain(args, new ScalacWorker());
  }

  @Override
  public void work(String[] args) throws Exception {
    CompileOptions ops = new CompileOptions(args);

    Path outputJar = Paths.get(ops.outputName);
    Path workdir = ensureEmptyWorkDirectory(outputJar, ops.currentTarget);
    Path classes = Files.createDirectories(workdir.resolve("classes"));
    Path sources = Files.createDirectories(workdir.resolve("sources"));

    List<File> jarFiles = extractSourceJars(ops, sources);
    List<File> scalaJarFiles = filterFilesByExtension(jarFiles, ".scala");
    List<File> javaJarFiles = filterFilesByExtension(jarFiles, ".java");

    if (!ops.expectJavaOutput && ops.javaFiles.length != 0) {
      throw new RuntimeException("Cannot have java source files when no expected java output");
    }

    if (!ops.expectJavaOutput && !javaJarFiles.isEmpty()) {
      throw new RuntimeException(
          "Found java files in source jars but expect Java output is set to false");
    }

    String[] scalaSources = collectSrcJarSources(ops.files, scalaJarFiles, javaJarFiles);

    String[] javaSources = appendToString(ops.javaFiles, javaJarFiles);
    if (scalaSources.length == 0 && javaSources.length == 0) {
      throw new RuntimeException("Must have input files from either source jars or local files.");
    }

    /**
     * Compile scala sources if available (if there are none, we will simply compile java sources).
     */
    if (scalaSources.length > 0) {
      compileScalaSources(ops, scalaSources, classes);
    }

    /** Copy the resources */
    copyResources(ops.resourceSources, ops.resourceTargets, classes);

    /** Extract and copy resources from resource jars */
    copyResourceJars(ops.resourceJars, classes);

    /** Copy classpath resources to root of jar */
    copyClasspathResourcesToRoot(ops.classpathResourceFiles, classes);

    /** Now build the output jar */
    String[] jarCreatorArgs = {
        "-m", ops.manifestPath, "-t", ops.stampLabel, outputJar.toString(), classes.toString()
    };
    JarCreator.main(jarCreatorArgs);
  }

  private static Path ensureEmptyWorkDirectory(Path output, String label) throws IOException {
    String base = label.substring(label.lastIndexOf(':') + 1);
    Path dir = output.resolveSibling("_scalac").resolve(base);

    if (Files.exists(dir)) {
      deleteRecursively(dir);
    }

    return Files.createDirectories(dir);
  }

  private static String[] collectSrcJarSources(
      String[] files, List<File> scalaJarFiles, List<File> javaJarFiles) {
    String[] scalaSources = appendToString(files, scalaJarFiles);
    return appendToString(scalaSources, javaJarFiles);
  }

  private static List<File> filterFilesByExtension(List<File> files, String extension) {
    List<File> filtered = new ArrayList<File>();
    for (File f : files) {
      if (f.toString().endsWith(extension)) {
        filtered.add(f);
      }
    }
    return filtered;
  }

  private static final String[] sourceExtensions = {".scala", ".java"};

  private static List<File> extractSourceJars(CompileOptions opts, Path sources)
      throws IOException {
    List<File> sourceFiles = new ArrayList<File>();

    for (int i = 0; i < opts.sourceJars.length; i++) {
      String jarPath = opts.sourceJars[i];
      if (jarPath.length() > 0) {
        String sourceJarFileName = String.format("%s_%s", i, Paths.get(jarPath).getFileName());
        Path sourceJarDestination = Files.createDirectories(sources.resolve(sourceJarFileName));
        sourceFiles.addAll(extractJar(jarPath, sourceJarDestination.toString(), sourceExtensions));
      }
    }

    return sourceFiles;
  }

  private static List<File> extractJar(String jarPath, String outputFolder, String[] extensions)
      throws IOException {

    List<File> outputPaths = new ArrayList<>();
    JarFile jar = new JarFile(jarPath);
    Enumeration<JarEntry> e = jar.entries();
    while (e.hasMoreElements()) {
      JarEntry file = e.nextElement();
      String thisFileName = file.getName();
      // we don't bother to extract non-scala/java sources (skip manifest)
      if (extensions != null && !matchesFileExtensions(thisFileName, extensions)) {
        continue;
      }
      File f = new File(outputFolder + File.separator + file.getName());

      if (file.isDirectory()) { // if it's a directory, create it
        f.mkdirs();
        continue;
      }

      File parent = f.getParentFile();
      parent.mkdirs();
      outputPaths.add(f);

      try (InputStream is = jar.getInputStream(file);
          OutputStream fos = new FileOutputStream(f)) {
        StreamCopy.copy(is, fos);
      }
    }
    return outputPaths;
  }

  private static boolean matchesFileExtensions(String fileName, String[] extensions) {
    for (String e : extensions) {
      if (fileName.endsWith(e)) {
        return true;
      }
    }
    return false;
  }

  private static String[] encodeBazelTargets(String[] targets) {
    return Arrays.stream(targets).map(ScalacWorker::encodeBazelTarget).toArray(String[]::new);
  }

  private static String encodeBazelTarget(String target) {
    return target.replace(":", ";");
  }

  private static boolean isModeEnabled(String mode) {
    return !"off".equals(mode);
  }

  public static String[] buildPluginArgs(String[] pluginElements) {
    int numPlugins = 0;
    for (int i = 0; i < pluginElements.length; i++) {
      if (pluginElements[i].length() > 0) {
        numPlugins += 1;
      }
    }

    String[] result = new String[numPlugins];
    int idx = 0;
    for (int i = 0; i < pluginElements.length; i++) {
      if (pluginElements[i].length() > 0) {
        result[idx] = "-Xplugin:" + pluginElements[i];
        idx += 1;
      }
    }
    return result;
  }

  private static String[] getPluginParamsFrom(CompileOptions ops) {
    List<String> pluginParams = new ArrayList<>(0);

    if ((isModeEnabled(ops.strictDepsMode) || isModeEnabled(ops.unusedDependencyCheckerMode)) &&
        !ops.dependencyTrackingMethod.equals("verbose-log")) {
      String currentTarget = encodeBazelTarget(ops.currentTarget);

      String[] dependencyAnalyzerParams = {
          "-P:dependency-analyzer:strict-deps-mode:" + ops.strictDepsMode,
          "-P:dependency-analyzer:unused-deps-mode:" + ops.unusedDependencyCheckerMode,
          "-P:dependency-analyzer:current-target:" + currentTarget,
          "-P:dependency-analyzer:dependency-tracking-method:" + ops.dependencyTrackingMethod,
      };

      pluginParams.addAll(Arrays.asList(dependencyAnalyzerParams));

      if (ops.directJars.length > 0) {
        pluginParams.add("-P:dependency-analyzer:direct-jars:" + String.join(":", ops.directJars));
      }
      if (ops.directTargets.length > 0) {
        String[] directTargets = encodeBazelTargets(ops.directTargets);
        pluginParams.add(
            "-P:dependency-analyzer:direct-targets:" + String.join(":", directTargets));
      }
      if (ops.indirectJars.length > 0) {
        pluginParams.add(
            "-P:dependency-analyzer:indirect-jars:" + String.join(":", ops.indirectJars));
      }
      if (ops.indirectTargets.length > 0) {
        String[] indirectTargets = encodeBazelTargets(ops.indirectTargets);
        pluginParams.add(
            "-P:dependency-analyzer:indirect-targets:" + String.join(":", indirectTargets));
      }
      if (ops.unusedDepsIgnoredTargets.length > 0) {
        String[] ignoredTargets = encodeBazelTargets(ops.unusedDepsIgnoredTargets);
        pluginParams.add(
            "-P:dependency-analyzer:unused-deps-ignored-targets:"
                + String.join(":", ignoredTargets));
      }
    }

    return pluginParams.toArray(new String[pluginParams.size()]);
  }

  private static void compileScalaSources(CompileOptions ops, String[] scalaSources, Path classes)
      throws IOException {

    String[] pluginArgs = buildPluginArgs(ops.plugins);
    String[] pluginParams = getPluginParamsFrom(ops);

    String[] constParams = {
        "-classpath", String.join(pathSeparator, ops.classpath), "-d", classes.toString()
    };

    String[] verboseLogOpt = ((isModeEnabled(ops.strictDepsMode) || isModeEnabled(ops.unusedDependencyCheckerMode)) && ops.dependencyTrackingMethod.equals("verbose-log")) ? new String[] {"-verbose"} : new String[]{};

    String[] compilerArgs =
        merge(ops.scalaOpts, verboseLogOpt, pluginArgs, constParams, pluginParams, scalaSources);

    ReportableMainClass comp = new ReportableMainClass(ops);

    long start = System.currentTimeMillis();
    try {
      comp.process(compilerArgs);
    } catch (Throwable ex) {
      if (ex.toString().contains("scala.reflect.internal.Types$TypeError")) {
        throw new RuntimeException("Build failure with type error", ex);
      } else {
        throw ex;
      }
    }
    long stop = System.currentTimeMillis();
    if (ops.printCompileTime) {
      System.err.println("Compiler runtime: " + (stop - start) + "ms.");
    }

    try {
      String buildTime = "";
      // If enable stats file we write the volatile string component
      // otherwise empty string for better remote cache performance.
      if (ops.enableStatsFile) {
        buildTime = Long.toString(stop - start);
      }
      Files.write(Paths.get(ops.statsfile), Arrays.asList("build_time=" + buildTime));
    } catch (IOException ex) {
      throw new RuntimeException("Unable to write statsfile to " + ops.statsfile, ex);
    }

    ConsoleReporter reporter = (ConsoleReporter) comp.getReporter();
    if (reporter instanceof ProtoReporter) {
      ProtoReporter protoReporter = (ProtoReporter) reporter;
      protoReporter.writeTo(Paths.get(ops.diagnosticsFile));
    }

    if (reporter instanceof DepsTrackingReporter) {
      ((DepsTrackingReporter) reporter).prepareReport();
    }

    if (reporter.hasErrors()) {
      reporter.flush();
      throw new RuntimeException("Build failed");
    }
  }

  private static void deleteRecursively(Path directory) throws IOException {
    if (directory != null) {
      Files.walkFileTree(
          directory,
          new SimpleFileVisitor<Path>() {
            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs)
                throws IOException {
              if (isWindows) {
                file.toFile().setWritable(true);
              }
              Files.delete(file);
              return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path dir, IOException exc)
                throws IOException {
              Files.delete(dir);
              return FileVisitResult.CONTINUE;
            }
          });
    }
  }

  private static void copyResources(String[] sources, String[] targets, Path dest)
      throws IOException {
    if (sources.length != targets.length) {
      throw new RuntimeException(
          String.format(
              "mismatch in resources: sources: %s targets: %s",
              Arrays.toString(sources), Arrays.toString(targets)));
    }

    for (int i = 0; i < sources.length; i++) {
      Path source = Paths.get(sources[i]);
      Path target = dest.resolve(targets[i]);
      target.getParent().toFile().mkdirs();
      Files.copy(source, target);
    }
  }

  private static void copyClasspathResourcesToRoot(String[] classpathResourceFiles, Path dest)
      throws IOException {
    for (String s : classpathResourceFiles) {
      Path source = Paths.get(s);
      Path target = dest.resolve(source.getFileName());

      if (Files.exists(target)) {
        System.err.println(
            "Classpath resource file "
                + source.getFileName()
                + " has a namespace conflict with another file: "
                + target.getFileName());
      } else {
        Files.copy(source, target);
      }
    }
  }

  private static void copyResourceJars(String[] resourceJars, Path dest) throws IOException {
    for (String jarPath : resourceJars) {
      extractJar(jarPath, dest.toString(), null);
    }
  }

  private static <T> String[] appendToString(String[] init, List<T> rest) {
    String[] tmp = new String[init.length + rest.size()];
    System.arraycopy(init, 0, tmp, 0, init.length);
    int baseIdx = init.length;
    for (T t : rest) {
      tmp[baseIdx] = t.toString();
      baseIdx += 1;
    }
    return tmp;
  }

  private static String[] merge(String[]... arrays) {
    int totalLength = 0;
    for (String[] arr : arrays) {
      totalLength += arr.length;
    }

    String[] result = new String[totalLength];
    int offset = 0;
    for (String[] arr : arrays) {
      System.arraycopy(arr, 0, result, offset, arr.length);
      offset += arr.length;
    }
    return result;
  }
}
