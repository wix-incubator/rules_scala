package io.bazel.rulesscala.test_discovery

import java.lang.reflect.Field

object ReflectionUtils {
  def getAllFields(clazz: Class[_]): Seq[Field] = {
    def getAllTypes(clazz: Class[_]) = {
      var types = Seq.empty[Class[_]]
      var c = clazz
      while (c != null) {
        types :+= c
        c = c.getSuperclass
      }
      types
    }

    getAllTypes(clazz)
      .map(_.getDeclaredFields)
      .flatMap(_.toSeq)
  }
}
