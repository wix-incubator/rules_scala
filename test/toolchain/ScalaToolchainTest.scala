package scala.test.toolchain

import com.google.common.collect.ImmutableList
import org.specs2.mutable.{Before, SpecificationWithJUnit}
import org.specs2.specification.{BeforeAll, Scope}
import build.bazel.tests.integration.BazelBaseTestCase
import scala.collection.JavaConverters._

class ScalaToolchainTest extends SpecificationWithJUnit with BeforeAll {

  trait ctx extends Scope with Before {
    val fubar = new BazelBaseTestCase {
      def pubScratchFile(path:String, content:String) = scratchFile(path,content)
      def pubBazel (args: String *) = bazel(args.asJava)
    }
    override def before = fubar.setUp()
  }

  "scala_library" should {
    "allow configuration of jvm flags for scalac" in new ctx {
      fubar.pubScratchFile("WillNotCompileScalaSinceXmxTooLow.scala", "class WillNotCompileScalaSinceXmxTooLow" )
      fubar.pubScratchFile("BUILD",
        """
          |scala_library(
          |    name = "can_configure_jvm_flags_for_scalac",
          |    srcs = ["WillNotCompileScalaSinceXmxTooLow.scala"],
          |)
        """.
          stripMargin)
      val cmd = fubar.pubBazel("build", "//:can_configure_jvm_flags_for_scalac")
      private val exitCode: Int = cmd.run()
      private val stderr: ImmutableList[String] = cmd.getErrorLines
      println(stderr)
      private val stdout: ImmutableList[String] = cmd.getOutputLines
      println(stdout)
      exitCode ==== 1
    }
  }
  override def beforeAll(): Unit = BazelBaseTestCase.setUpClass()

}