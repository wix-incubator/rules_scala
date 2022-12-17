package io.bazel.rulesscala.dependencyanalyzer

import io.bazel.rulesscala.scalac.reporter.DepsTrackingReporter

import scala.collection.JavaConverters._
import scala.tools.nsc.Global

/**
* Scala 2.13 reporter extends FilteringReported, which
* filters messages based on
*  - settings.nowarn
*  - settings.maxerrs / settings.maxwarns
*  - positions (only one error at a position, no duplicate messages on a position)
* Controlling compiler flags: -Xprompt, -Vdebug
*
* This class avoids filtering for AST analyzer
*/
class Reporter(global: Global) {
  def registerAstJars(usedJarPathToPositions: Map[String, Reporter.this.global.Position]): Unit = {
    global.reporter match {
      case r: DepsTrackingReporter => r.registerAstUsedJars(usedJarPathToPositions.keys.toSet.asJava)
      case _ =>
    }
  }

  def error(pos: global.Position, message: String): Unit = {
    global.reporter.increment(global.reporter.ERROR)
    global.reporter.doReport(pos, message, global.reporter.ERROR)
  }

  def warning(pos: global.Position, message: String): Unit = {
    global.reporter.increment(global.reporter.WARNING)
    global.reporter.doReport(pos, message, global.reporter.WARNING)
  }
}
