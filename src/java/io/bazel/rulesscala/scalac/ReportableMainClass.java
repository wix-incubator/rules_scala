package io.bazel.rulesscala.scalac;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import scala.tools.nsc.Global;
import scala.tools.nsc.MainClass;
import scala.tools.nsc.Settings;
import scala.tools.nsc.reporters.Reporter;

public class ReportableMainClass extends MainClass {
  private Global compiler;
  private Reporter reporter;
  private final CompileOptions ops;

  public ReportableMainClass(CompileOptions ops) {
    this.ops = ops;
  }

  @Override
  public Global newCompiler() {
    createDiagnosticsFile();
    if (!ops.enableDiagnosticsReport && !ops.dependencyTrackingMethod.equals("verbose-log")) {
      Global global = super.newCompiler();
      reporter = global.reporter();
      return global;
    } else {
      Settings settings = super.settings();
      if (ops.enableDiagnosticsReport) {
        reporter = new ProtoReporter(settings);
      }

      if (ops.dependencyTrackingMethod.equals("verbose-log")) {
        reporter = new DepsTrackingReporter(settings, ops, reporter);
      }

      compiler = new Global(settings, reporter);
      return compiler;
    }
  }

  private void createDiagnosticsFile() {
    Path path = Paths.get(ops.diagnosticsFile);
    try {
      Files.deleteIfExists(path);
      Files.createFile(path);
    } catch (IOException e) {
      throw new RuntimeException("Could not delete/make diagnostics proto file", e);
    }
  }

  public Reporter getReporter() {
    return this.reporter;
  }
}
