package plugin.src.test.io.bazel.rulesscala.dependencyanalyzer

import java.io.File
import java.nio.file.Paths

import coursier.maven.MavenRepository
import coursier.{Cache, Dependency, Fetch, Resolution}

import scala.reflect.internal.util.BatchSourceFile
import scala.reflect.io.VirtualDirectory
import scala.tools.cmd.CommandLineParser
import scala.tools.nsc.reporters.StoreReporter
import scala.tools.nsc.{CompilerCommand, Global, Settings}
import scalaz.concurrent.Task

object TestUtil {

  import scala.language.postfixOps

  def run(code: String, withDirect: Seq[String] = Seq.empty, withIndirect: Map[String, String] = Map.empty): Seq[String] = {
    val compileOptions = Seq(
      constructParam("direct-jars", withDirect),
      constructParam("indirect-jars", withIndirect.keys),
      constructParam("indirect-targets", withIndirect.values)
    ).mkString(" ")

    val extraClasspath = withDirect ++ withIndirect.keys

    val reporter: StoreReporter = runCompilation(code, compileOptions, extraClasspath)
    reporter.infos.collect({ case msg if msg.severity == reporter.ERROR => msg.msg }).toSeq
  }

  private def runCompilation(code: String, compileOptions: String, extraClasspath: Seq[String]) = {
    val fullClasspath: String = {
      val extraClasspathString = extraClasspath.mkString(":")
      if (toolboxClasspath.isEmpty) extraClasspathString
      else s"$toolboxClasspath:$extraClasspathString"
    }
    val basicOptions =
      createBasicCompileOptions(fullClasspath, toolboxPluginOptions)

    eval(code, s"$basicOptions $compileOptions")
  }

  /** Evaluate using global instance instead of toolbox because toolbox seems
    * to fail to typecheck code that comes from external dependencies. */
  private def eval(code: String, compileOptions: String = ""): StoreReporter = {
    // TODO: Optimize and cache global.
    val options = CommandLineParser.tokenize(compileOptions)
    val reporter = new StoreReporter()
    val settings = new Settings(println)
    val _ = new CompilerCommand(options, settings)
    settings.outputDirs.setSingleOutput(new VirtualDirectory("(memory)", None))
    val global = new Global(settings, reporter)
    val run = new global.Run
    val toCompile = new BatchSourceFile("<wrapper-init>", code)
    run.compileSources(List(toCompile))
    reporter
  }

  lazy val baseDir = System.getProperty("user.dir")

  lazy val toolboxClasspath: String = {
    val jar = System.getProperty("scala.library.location")
    val libPath = Paths.get(baseDir, jar).toAbsolutePath
    libPath.toString
  }

  lazy val toolboxPluginOptions: String = {
    val jar = System.getProperty("plugin.jar.location")
    val start= jar.indexOf("/plugin")
    // this substring is needed due to issue: https://github.com/bazelbuild/bazel/issues/2475
    val jarInRelationToBaseDir = jar.substring(start, jar.length)
    val pluginPath = Paths.get(baseDir, jarInRelationToBaseDir).toAbsolutePath
    s"-Xplugin:${pluginPath} -Jdummy=${pluginPath.toFile.lastModified}"
  }

  private def createBasicCompileOptions(classpath: String, usePluginOptions: String) =
    s"-classpath $classpath $usePluginOptions"

  private def constructParam(name: String, values: Iterable[String]) = {
    if (values.isEmpty) ""
    else s"-P:dependency-analyzer:$name:${values.mkString(":")}"
  }

  object Coursier {
    private final val repositories = Seq(
      Cache.ivy2Local,
      MavenRepository("https://repo1.maven.org/maven2")
    )

    def getArtifact(dependency: Dependency) = getArtifacts(Seq(dependency)).head

    private def getArtifacts(deps: Seq[Dependency]): Seq[String] =
      getArtifacts(deps, toAbsolutePath)

    private def getArtifacts(deps: Seq[Dependency], fileToString: File => String): Seq[String] = {
      val toResolve = Resolution(deps.toSet)
      val fetch = Fetch.from(repositories, Cache.fetch())
      val resolution = toResolve.process.run(fetch).run
      val resolutionErrors = resolution.errors
      if (resolutionErrors.nonEmpty)
        sys.error(s"Modules could not be resolved:\n$resolutionErrors.")
      val errorsOrJars = Task
        .gatherUnordered(resolution.artifacts.map(Cache.file(_).run))
        .unsafePerformSync
      val onlyErrors = errorsOrJars.filter(_.isLeft)
      if (onlyErrors.nonEmpty)
        sys.error(s"Jars could not be fetched from cache:\n$onlyErrors")
      errorsOrJars.flatMap(_.map(fileToString).toList)
    }

    private def toAbsolutePath(f: File): String =
      f.getAbsolutePath

  }

}
