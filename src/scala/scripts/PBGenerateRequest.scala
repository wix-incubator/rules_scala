package scripts

import java.nio.file.{Files, Path, Paths}

class PBGenerateRequest(val jarOutput: String, val scalaPBOutput: Path, val scalaPBArgs: List[String], val protoc: Path)

object PBGenerateRequest {

  def from(args: java.util.List[String]): PBGenerateRequest = {
    val jarOutput = args.get(0)
    val parsedProtoFiles = args.get(1).split(':').toList.map { rootAndFile =>
      val parsed = rootAndFile.split(',')
      val root = parsed(0)
      val file = if (root.isEmpty) {
        parsed(1)
      } else {
        parsed(1).substring(root.length).stripPrefix("/")
      }
      (file, Paths.get(root, file).toString)
    }
    // This will map the absolute path of a given proto file
    // to a relative path that does not contain the repo prefix.
    // This is to match the expected behavior of
    // proto_library and java_proto_library where proto files
    // can import other proto files using only the relative path
    val imports = parsedProtoFiles.map { case (relPath, absolutePath) =>
      s"-I$relPath=$absolutePath"
    }
    val protoFiles = args.get(4).split(':')
    val flagOpt = args.get(2) match {
      case "-" => None
      case s if s.charAt(0) == '-' => Some(s.tail) //drop padding character
      case other => sys.error(s"expected a padding character of - (dash), but found: $other")
    }
    val transitiveProtoPaths = args.get(3) match {
      case "-" => Nil
      case s if s.charAt(0) == '-' => s.tail.split(':').toList //drop padding character
      case other => sys.error(s"expected a padding character of - (dash), but found: $other")
    }

    val tmp = Paths.get(Option(System.getProperty("java.io.tmpdir")).getOrElse("/tmp"))
    val scalaPBOutput = Files.createTempDirectory(tmp, "bazelscalapb")
    val flagPrefix = flagOpt.fold("")(_ + ":")
    val scalaPBArgs = s"--scala_out=$flagPrefix$scalaPBOutput" :: (padWithProtoPathPrefix(transitiveProtoPaths) ++ imports ++ protoFiles)
    val protoc = Paths.get(args.get(5))
    new PBGenerateRequest(jarOutput, scalaPBOutput, scalaPBArgs, protoc)
  }

  private def padWithProtoPathPrefix(transitiveProtoPathFlags: List[String]) =
    transitiveProtoPathFlags.map("--proto_path="+_)

}
