// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager2.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/type_system.dart';

class InheritanceOverrideVerifier {
  static const _missingOverridesKey = 'missingOverrides';

  final StrongTypeSystemImpl _typeSystem;
  final TypeProvider _typeProvider;
  final InheritanceManager2 _inheritance;
  final ErrorReporter _reporter;

  InheritanceOverrideVerifier(
      this._typeSystem, this._inheritance, this._reporter)
      : _typeProvider = _typeSystem.typeProvider;

  void verifyUnit(CompilationUnit unit) {
    var library = unit.declaredElement.library;
    for (var declaration in unit.declarations) {
      if (declaration is ClassDeclaration) {
        new _ClassVerifier(
          typeSystem: _typeSystem,
          typeProvider: _typeProvider,
          inheritance: _inheritance,
          reporter: _reporter,
          library: library,
          classNameNode: declaration.name,
          implementsClause: declaration.implementsClause,
          members: declaration.members,
          superclass: declaration.extendsClause?.superclass,
          withClause: declaration.withClause,
        ).verify();
      } else if (declaration is ClassTypeAlias) {
        new _ClassVerifier(
          typeSystem: _typeSystem,
          typeProvider: _typeProvider,
          inheritance: _inheritance,
          reporter: _reporter,
          library: library,
          classNameNode: declaration.name,
          implementsClause: declaration.implementsClause,
          superclass: declaration.superclass,
          withClause: declaration.withClause,
        ).verify();
      } else if (declaration is MixinDeclaration) {
        new _ClassVerifier(
          typeSystem: _typeSystem,
          typeProvider: _typeProvider,
          inheritance: _inheritance,
          reporter: _reporter,
          library: library,
          classNameNode: declaration.name,
          implementsClause: declaration.implementsClause,
          members: declaration.members,
          onClause: declaration.onClause,
        ).verify();
      }
    }
  }

  /// Returns [ExecutableElement]s that are in the interface of the given
  /// class, but don't have concrete implementations.
  static List<ExecutableElement> missingOverrides(ClassDeclaration node) {
    return node.name.getProperty(_missingOverridesKey) ?? const [];
  }
}

class _ClassVerifier {
  final StrongTypeSystemImpl typeSystem;
  final TypeProvider typeProvider;
  final InheritanceManager2 inheritance;
  final ErrorReporter reporter;

  final LibraryElement library;
  final ClassElementImpl classElement;

  final SimpleIdentifier classNameNode;
  final List<ClassMember> members;
  final ImplementsClause implementsClause;
  final OnClause onClause;
  final TypeName superclass;
  final WithClause withClause;

  _ClassVerifier({
    this.typeSystem,
    this.typeProvider,
    this.inheritance,
    this.reporter,
    this.library,
    this.classNameNode,
    this.implementsClause,
    this.members: const [],
    this.onClause,
    this.superclass,
    this.withClause,
  }) : classElement =
            AbstractClassElementImpl.getImpl(classNameNode.staticElement);

  void verify() {
    ClassElementImpl element =
        AbstractClassElementImpl.getImpl(classNameNode.staticElement);
    LibraryElement library = element.library;
    InterfaceTypeImpl type = element.type;

    if (_checkDirectSuperTypes()) {
      return;
    }

    var allSuperinterfaces = <InterfaceType>[];

    // Add all superinterfaces of the direct supertype.
    if (type.superclass != null) {
      ClassElementImpl.collectAllSupertypes(
          allSuperinterfaces, type.superclass, null);
    }

    // Each mixin in `class C extends S with M0, M1, M2 {}` is equivalent to:
    //   class S&M0 extends S { ...members of M0... }
    //   class S&M1 extends S&M0 { ...members of M1... }
    //   class S&M2 extends S&M1 { ...members of M2... }
    //   class C extends S&M2 { ...members of C... }
    // So, we need to check members of each mixin against superinterfaces
    // of `S`, and superinterfaces of all previous mixins.
    var mixinNodes = withClause?.mixinTypes;
    var mixinTypes = type.mixins;
    for (var i = 0; i < mixinTypes.length; i++) {
      _checkDeclaredMembers(allSuperinterfaces, mixinNodes[i], mixinTypes[i]);
      ClassElementImpl.collectAllSupertypes(
          allSuperinterfaces, mixinTypes[i], null);
    }

    // Add all superinterfaces of the direct class interfaces.
    for (var interface in type.interfaces) {
      ClassElementImpl.collectAllSupertypes(
          allSuperinterfaces, interface, null);
    }

    // Check the members if the class itself, against all the previously
    // collected superinterfaces of the supertype, mixins, and interfaces.
    for (var member in members) {
      if (member is FieldDeclaration) {
        var fieldList = member.fields;
        for (var field in fieldList.variables) {
          FieldElement fieldElement = field.declaredElement;
          _checkDeclaredMember(
              allSuperinterfaces, fieldList, fieldElement.getter);
          _checkDeclaredMember(
              allSuperinterfaces, fieldList, fieldElement.setter);
        }
      } else if (member is MethodDeclaration) {
        _checkDeclaredMember(
            allSuperinterfaces, member, member.declaredElement);
      }
    }

    // Compute the interface of the class.
    var interfaceMembers = inheritance.getInterface(type);

    // Report conflicts between direct superinterfaces of the class.
    for (var conflict in interfaceMembers.conflicts) {
      _reportInconsistentInheritance(classNameNode, conflict);
    }

    if (!element.isAbstract) {
      var libraryUri = library.source.uri;
      List<ExecutableElement> inheritedAbstractMembers = null;

      for (var name in interfaceMembers.map.keys) {
        if (!name.isAccessibleFor(libraryUri)) {
          continue;
        }

        var interfaceType = interfaceMembers.map[name];
        var concreteType = inheritance.getMember(type, name, concrete: true);

        // No concrete implementation of the name.
        if (concreteType == null) {
          if (!element.hasNoSuchMethod) {
            if (!_reportConcreteClassWithAbstractMember(name.name)) {
              inheritedAbstractMembers ??= [];
              inheritedAbstractMembers.add(interfaceType.element);
            }
          }
          continue;
        }

        // The case when members have different kinds is reported in verifier.
        if (concreteType.element.kind != interfaceType.element.kind) {
          continue;
        }

        // If a class declaration is not abstract, and the interface has a
        // member declaration named `m`, then:
        // 1. if the class contains a non-overridden member whose signature is
        //    not a valid override of the interface member signature for `m`,
        //    then it's a compile-time error.
        // 2. if the class contains no member named `m`, and the class member
        //    for `noSuchMethod` is the one declared in `Object`, then it's a
        //    compile-time error.
        if (!typeSystem.isOverrideSubtypeOf(concreteType, interfaceType)) {
          reporter.reportErrorForNode(
            CompileTimeErrorCode.INVALID_OVERRIDE,
            classNameNode,
            [
              name.name,
              concreteType.element.enclosingElement.name,
              concreteType.displayName,
              interfaceType.element.enclosingElement.name,
              interfaceType.displayName,
            ],
          );
        }
      }

      _reportInheritedAbstractMembers(inheritedAbstractMembers);
    }
  }

  /// Check that the given [member] is a valid override of the corresponding
  /// instance members in each of [allSuperinterfaces].
  void _checkDeclaredMember(
    List<InterfaceType> allSuperinterfaces,
    AstNode node,
    ExecutableElement member,
  ) {
    if (member == null) return;
    if (member.isStatic) return;

    var name = member.name;
    for (var supertype in allSuperinterfaces) {
      var superMember = _getInstanceMember(supertype, name);
      if (superMember != null && superMember.isAccessibleIn(member.library)) {
        // The case when members have different kinds is reported in verifier.
        // TODO(scheglov) Do it here?
        if (member.kind != superMember.kind) {
          continue;
        }

        if (!typeSystem.isOverrideSubtypeOf(member.type, superMember.type)) {
          reporter.reportErrorForNode(
            CompileTimeErrorCode.INVALID_OVERRIDE,
            node,
            [
              name,
              member.enclosingElement.name,
              member.type.displayName,
              superMember.enclosingElement.name,
              superMember.type.displayName
            ],
          );
        }
      }
    }
  }

  /// Check that instance members of [type] are valid overrides of the
  /// corresponding instance members in each of [allSuperinterfaces].
  void _checkDeclaredMembers(
    List<InterfaceType> allSuperinterfaces,
    AstNode node,
    InterfaceTypeImpl type,
  ) {
    for (var method in type.methods) {
      _checkDeclaredMember(allSuperinterfaces, node, method);
    }
    for (var accessor in type.accessors) {
      _checkDeclaredMember(allSuperinterfaces, node, accessor);
    }
  }

  /// Verify that the given [typeName] does not extend, implement, or mixes-in
  /// types such as `num` or `String`.
  bool _checkDirectSuperType(TypeName typeName, ErrorCode errorCode) {
    if (typeName.isSynthetic) {
      return false;
    }

    // The SDK implementation may implement disallowed types. For example,
    // JSNumber in dart2js and _Smi in Dart VM both implement int.
    if (library.source.isInSystemLibrary) {
      return false;
    }

    DartType type = typeName.type;
    if (typeProvider.nonSubtypableTypes.contains(type)) {
      reporter.reportErrorForNode(errorCode, typeName, [type.displayName]);
      return true;
    }

    return false;
  }

  /// Verify that direct supertypes are valid, and return `false`.  If there
  /// are direct supertypes that are not valid, report corresponding errors,
  /// and return `true`.
  bool _checkDirectSuperTypes() {
    var hasError = false;
    if (implementsClause != null) {
      for (var typeName in implementsClause.interfaces) {
        if (_checkDirectSuperType(
          typeName,
          CompileTimeErrorCode.IMPLEMENTS_DISALLOWED_CLASS,
        )) {
          hasError = true;
        }
      }
    }
    if (onClause != null) {
      for (var typeName in onClause.superclassConstraints) {
        if (_checkDirectSuperType(
          typeName,
          CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_DISALLOWED_CLASS,
        )) {
          hasError = true;
        }
      }
    }
    if (superclass != null) {
      if (_checkDirectSuperType(
        superclass,
        CompileTimeErrorCode.EXTENDS_DISALLOWED_CLASS,
      )) {
        hasError = true;
      }
    }
    if (withClause != null) {
      for (var typeName in withClause.mixinTypes) {
        if (_checkDirectSuperType(
          typeName,
          CompileTimeErrorCode.MIXIN_OF_DISALLOWED_CLASS,
        )) {
          hasError = true;
        }
      }
    }
    return hasError;
  }

  /// Return the instance member given the [name], defined in the [type],
  /// or `null` if the [type] does not define a member with the [name], or
  /// if it is not an instance member.
  ExecutableElement _getInstanceMember(InterfaceType type, String name) {
    ExecutableElement result;
    if (name.endsWith('=')) {
      name = name.substring(0, name.length - 1);
      result = type.getSetter(name);
    } else {
      result = type.getMethod(name) ?? type.getGetter(name);
    }
    if (result != null && result.isStatic) {
      result = null;
    }
    return result;
  }

  /// We identified that the current non-abstract class does not have the
  /// concrete implementation of a method with the given [name].  If this is
  /// because the class itself defines an abstract method with this [name],
  /// report the more specific error, and return `true`.
  bool _reportConcreteClassWithAbstractMember(String name) {
    for (var member in members) {
      if (member is MethodDeclaration) {
        var name2 = member.name.name;
        if (member.isSetter) {
          name2 += '=';
        }
        if (name2 == name) {
          reporter.reportErrorForNode(
              StaticWarningCode.CONCRETE_CLASS_WITH_ABSTRACT_MEMBER,
              member,
              [name, classElement.name]);
          return true;
        }
      }
    }
    return false;
  }

  void _reportInconsistentInheritance(AstNode node, Conflict conflict) {
    var name = conflict.name;

    if (conflict.getter != null && conflict.method != null) {
      reporter.reportErrorForNode(
        CompileTimeErrorCode.INCONSISTENT_INHERITANCE_GETTER_AND_METHOD,
        node,
        [
          name.name,
          conflict.getter.element.enclosingElement.name,
          conflict.method.element.enclosingElement.name
        ],
      );
    } else {
      var candidatesStr = conflict.candidates.map((candidate) {
        var className = candidate.element.enclosingElement.name;
        return '$className.${name.name} (${candidate.displayName})';
      }).join(', ');

      reporter.reportErrorForNode(
        CompileTimeErrorCode.INCONSISTENT_INHERITANCE,
        node,
        [name.name, candidatesStr],
      );
    }
  }

  void _reportInheritedAbstractMembers(List<ExecutableElement> elements) {
    if (elements == null) {
      return;
    }

    classNameNode.setProperty(
      InheritanceOverrideVerifier._missingOverridesKey,
      elements,
    );

    var descriptions = <String>[];
    for (ExecutableElement element in elements) {
      String prefix = '';
      if (element is PropertyAccessorElement) {
        if (element.isGetter) {
          prefix = 'getter ';
        } else {
          prefix = 'setter ';
        }
      }

      String description;
      var elementName = element.displayName;
      var enclosingElement = element.enclosingElement;
      if (enclosingElement != null) {
        var enclosingName = element.enclosingElement.displayName;
        description = "$prefix$enclosingName.$elementName";
      } else {
        description = "$prefix$elementName";
      }

      descriptions.add(description);
    }
    descriptions.sort();

    if (descriptions.length == 1) {
      reporter.reportErrorForNode(
        StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_ONE,
        classNameNode,
        [descriptions[0]],
      );
    } else if (descriptions.length == 2) {
      reporter.reportErrorForNode(
        StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_TWO,
        classNameNode,
        [descriptions[0], descriptions[1]],
      );
    } else if (descriptions.length == 3) {
      reporter.reportErrorForNode(
        StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_THREE,
        classNameNode,
        [descriptions[0], descriptions[1], descriptions[2]],
      );
    } else if (descriptions.length == 4) {
      reporter.reportErrorForNode(
        StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_FOUR,
        classNameNode,
        [descriptions[0], descriptions[1], descriptions[2], descriptions[3]],
      );
    } else {
      reporter.reportErrorForNode(
        StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_FIVE_PLUS,
        classNameNode,
        [
          descriptions[0],
          descriptions[1],
          descriptions[2],
          descriptions[3],
          descriptions.length - 4
        ],
      );
    }
  }
}
