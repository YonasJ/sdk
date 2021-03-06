// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * This part contains helpers for supporting runtime type information.
 *
 * The helper use a mixture of Dart and JavaScript objects. To indicate which is
 * used where we adopt the scheme of using explicit type annotation for Dart
 * objects and 'var' or omitted return type for JavaScript objects.
 *
 * Since bool, int, and String values are represented by the same JavaScript
 * primitives, type annotations are used for these types in all cases.
 *
 * Several methods use a common JavaScript encoding of runtime type information.
 * This encoding is referred to as the type representation which is one of
 * these:
 *  1) a JavaScript constructor for a class C: the represented type is the raw
 *     type C.
 *  2) a JavaScript array: the first entry is of type 1 and contains the
 *     subtyping flags and the substitution of the type and the rest of the
 *     array are the type arguments.
 *  3) `null`: the dynamic type.
 *  4) a JavaScript object representing the function type. For instance, it has
 *     the form {ret: rti, args: [rti], opt: [rti], named: {name: rti}} for a
 *     function with a return type, regular, optional and named arguments.
 *     Generic function types have a 'bounds' property.
 *
 * To check subtype relations between generic classes we use a JavaScript
 * expression that describes the necessary substitution for type arguments.
 * Such a substitution expression can be:
 *  1) `null`, if no substituted check is necessary, because the
 *     type variables are the same or there are no type variables in the class
 *     that is checked for.
 *  2) A list expression describing the type arguments to be used in the
 *     subtype check, if the type arguments to be used in the check do not
 *     depend on the type arguments of the object.
 *  3) A function mapping the type variables of the object to be checked to
 *     a list expression. The function may also return null, which is equivalent
 *     to an array containing only null values.
 */

part of _js_helper;

Type createRuntimeType(String name) {
  // Use a 'JS' cast to String.  Since this is registered as used by the
  // backend, type inference assumes the worst (name is dynamic).
  return new TypeImpl(JS('String', '#', name));
}

class TypeImpl implements Type {
  final String _typeName;
  String _unmangledName;

  TypeImpl(this._typeName);

  String toString() {
    if (_unmangledName != null) return _unmangledName;
    String unmangledName = unmangleAllIdentifiersIfPreservedAnyways(_typeName);
    return _unmangledName = unmangledName;
  }

  // TODO(ahe): This is a poor hashCode as it collides with its name.
  int get hashCode => _typeName.hashCode;

  bool operator ==(other) {
    return (other is TypeImpl) && _typeName == other._typeName;
  }
}

/**
 * Represents a type variable.
 *
 * This class holds the information needed when reflecting on generic classes
 * and their members.
 */
class TypeVariable {
  final Type owner;
  final String name;
  final int bound;

  const TypeVariable(this.owner, this.name, this.bound);
}

getMangledTypeName(TypeImpl type) => type._typeName;

/// Sets the runtime type information on [target]. [rti] is a type
/// representation of type 4 or 5, that is, either a JavaScript array or `null`.
///
/// Called from generated code.
///
/// This is used only for marking JavaScript Arrays (JSArray) with the element
/// type.
// Don't inline.  Let the JS engine inline this.  The call expression is much
// more compact that the inlined expansion.
@NoInline()
Object setRuntimeTypeInfo(Object target, var rti) {
  assert(rti == null || isJsArray(rti));
  String rtiName = JS_GET_NAME(JsGetName.RTI_NAME);
  JS('var', r'#[#] = #', target, rtiName, rti);
  return target;
}

/// Returns the runtime type information of [target]. The returned value is a
/// list of type representations for the type arguments.
///
/// Called from generated code.
getRuntimeTypeInfo(Object target) {
  if (target == null) return null;
  String rtiName = JS_GET_NAME(JsGetName.RTI_NAME);
  return JS('var', r'#[#]', target, rtiName);
}

/**
 * Returns the type arguments of [target] as an instance of [substitutionName].
 */
getRuntimeTypeArguments(target, substitutionName) {
  var substitution = getField(
      target, '${JS_GET_NAME(JsGetName.OPERATOR_AS_PREFIX)}$substitutionName');
  return substitute(substitution, getRuntimeTypeInfo(target));
}

/// Returns the [index]th type argument of [target] as an instance of
/// [substitutionName].
///
/// Called from generated code.
@NoThrows()
@NoSideEffects()
@NoInline()
getRuntimeTypeArgument(Object target, String substitutionName, int index) {
  var arguments = getRuntimeTypeArguments(target, substitutionName);
  return arguments == null ? null : getIndex(arguments, index);
}

/// Returns the [index]th type argument of [target].
///
/// Called from generated code.
@NoThrows()
@NoSideEffects()
@NoInline()
getTypeArgumentByIndex(Object target, int index) {
  var rti = getRuntimeTypeInfo(target);
  return rti == null ? null : getIndex(rti, index);
}

/**
 * Retrieves the class name from type information stored on the constructor
 * of [object].
 */
String getClassName(var object) {
  return rawRtiToJsConstructorName(getRawRuntimeType(getInterceptor(object)));
}

/**
 * Creates the string representation for the type representation [rti]
 * of type 4, the JavaScript array, where the first element represents the class
 * and the remaining elements represent the type arguments.
 */
String _getRuntimeTypeAsStringV1(var rti, {String onTypeVariable(int i)}) {
  assert(isJsArray(rti));
  String className = rawRtiToJsConstructorName(getIndex(rti, 0));
  return '$className${joinArgumentsV1(rti, 1, onTypeVariable: onTypeVariable)}';
}

String _getRuntimeTypeAsStringV2(var rti, List<String> genericContext) {
  assert(isJsArray(rti));
  String className = rawRtiToJsConstructorName(getIndex(rti, 0));
  return '$className${joinArgumentsV2(rti, 1, genericContext)}';
}

/// Returns a human-readable representation of the type representation [rti].
///
/// Called from generated code.
///
/// [onTypeVariable] is used only from dart:mirrors.
@NoInline()
String runtimeTypeToString(var rti, {String onTypeVariable(int i)}) {
  return JS_GET_FLAG('STRONG_MODE')
      ? runtimeTypeToStringV2(rti, null)
      : runtimeTypeToStringV1(rti, onTypeVariable: onTypeVariable);
}

String runtimeTypeToStringV1(var rti, {String onTypeVariable(int i)}) {
  if (rti == null) {
    return 'dynamic';
  }
  if (isJsArray(rti)) {
    // A list representing a type with arguments.
    return _getRuntimeTypeAsStringV1(rti, onTypeVariable: onTypeVariable);
  }
  if (isJsFunction(rti)) {
    // A reference to the constructor.
    return rawRtiToJsConstructorName(rti);
  }
  if (rti is int) {
    return '${onTypeVariable == null ? rti : onTypeVariable(rti)}';
  }
  String functionPropertyName = JS_GET_NAME(JsGetName.FUNCTION_TYPE_TAG);
  if (JS('bool', 'typeof #[#] != "undefined"', rti, functionPropertyName)) {
    // If the RTI has typedef equivalence info (via mirrors), use that since the
    // mirrors helpers will re-parse the generated string.

    String typedefPropertyName = JS_GET_NAME(JsGetName.TYPEDEF_TAG);
    var typedefInfo = JS('', '#[#]', rti, typedefPropertyName);
    if (typedefInfo != null) {
      return runtimeTypeToStringV1(typedefInfo, onTypeVariable: onTypeVariable);
    }
    return _functionRtiToStringV1(rti, onTypeVariable);
  }
  // We should not get here.
  return 'unknown-reified-type';
}

String runtimeTypeToStringV2(var rti, List<String> genericContext) {
  if (rti == null) {
    return 'dynamic';
  }
  if (isJsArray(rti)) {
    // A list representing a type with arguments.
    return _getRuntimeTypeAsStringV2(rti, genericContext);
  }
  if (isJsFunction(rti)) {
    // A reference to the constructor.
    return rawRtiToJsConstructorName(rti);
  }
  if (isGenericFunctionTypeParameter(rti)) {
    int index = rti;
    if (genericContext == null || index < 0 || index >= genericContext.length) {
      return 'unexpected-generic-index:${index}';
    }
    return '${genericContext[genericContext.length - index - 1]}';
  }
  String functionPropertyName = JS_GET_NAME(JsGetName.FUNCTION_TYPE_TAG);
  if (JS('bool', 'typeof #[#] != "undefined"', rti, functionPropertyName)) {
    // TODO(sra): If there is a typedef tag, use the typedef name.
    return _functionRtiToStringV2(rti, genericContext);
  }
  // We should not get here.
  return 'unknown-reified-type';
}

String _functionRtiToStringV1(var rti, String onTypeVariable(int i)) {
  String returnTypeText;
  String voidTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_VOID_RETURN_TAG);
  if (JS('bool', '!!#[#]', rti, voidTag)) {
    returnTypeText = 'void';
  } else {
    String returnTypeTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_RETURN_TYPE_TAG);
    var returnRti = JS('', '#[#]', rti, returnTypeTag);
    returnTypeText =
        runtimeTypeToStringV1(returnRti, onTypeVariable: onTypeVariable);
  }

  String argumentsText = '';
  String sep = '';

  String requiredParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_REQUIRED_PARAMETERS_TAG);
  bool hasArguments = JS('bool', '# in #', requiredParamsTag, rti);
  if (hasArguments) {
    List arguments = JS('JSFixedArray', '#[#]', rti, requiredParamsTag);
    for (var argument in arguments) {
      argumentsText += sep;
      argumentsText +=
          runtimeTypeToStringV1(argument, onTypeVariable: onTypeVariable);
      sep = ', ';
    }
  }

  String optionalParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_OPTIONAL_PARAMETERS_TAG);
  bool hasOptionalArguments = JS('bool', '# in #', optionalParamsTag, rti);
  if (hasOptionalArguments) {
    List optionalArguments = JS('JSFixedArray', '#[#]', rti, optionalParamsTag);
    argumentsText += '$sep[';
    sep = '';
    for (var argument in optionalArguments) {
      argumentsText += sep;
      argumentsText +=
          runtimeTypeToStringV1(argument, onTypeVariable: onTypeVariable);
      sep = ', ';
    }
    argumentsText += ']';
  }

  String namedParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_NAMED_PARAMETERS_TAG);
  bool hasNamedArguments = JS('bool', '# in #', namedParamsTag, rti);
  if (hasNamedArguments) {
    var namedArguments = JS('', '#[#]', rti, namedParamsTag);
    argumentsText += '$sep{';
    sep = '';
    for (String name in extractKeys(namedArguments)) {
      argumentsText += sep;
      argumentsText += runtimeTypeToStringV1(
          JS('', '#[#]', namedArguments, name),
          onTypeVariable: onTypeVariable);
      argumentsText += ' $name';
      sep = ', ';
    }
    argumentsText += '}';
  }

  // TODO(sra): Below is the same format as the VM. Change to:
  //
  //     '${returnTypeText} Function(${argumentsText})';
  //
  return '(${argumentsText}) => ${returnTypeText}';
}

// Returns a formatted String version of a function type.
//
// [genericContext] is list of the names of generic type parameters for generic
// function types. The de Bruijn indexing scheme references the type variables
// from the inner scope out. The parameters for each scope are pushed in
// reverse, e.g.  `<P,Q>(<R,S,T>(R))` creates the list `[Q,P,T,S,R]`. This
// allows the de Bruijn index to simply index backwards from the end of
// [genericContext], e.g. in the outer scope index `0` is P and `1` is Q, and in
// the inner scope index `0` is R, `3` is P, and `4` is Q.
//
// [genericContext] is initially `null`.
String _functionRtiToStringV2(var rti, List<String> genericContext) {
  String typeParameters = '';
  int outerContextLength;

  String boundsTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_GENERIC_BOUNDS_TAG);
  if (hasField(rti, boundsTag)) {
    List boundsRti = JS('JSFixedArray', '#[#]', rti, boundsTag);
    if (genericContext == null) {
      genericContext = <String>[];
    } else {
      outerContextLength = genericContext.length;
    }
    int offset = genericContext.length;
    for (int i = boundsRti.length; i > 0; i--) {
      genericContext.add('T${offset + i}');
    }
    // All variables are in scope in the bounds.
    String typeSep = '';
    typeParameters = '<';
    for (int i = 0; i < boundsRti.length; i++) {
      typeParameters += typeSep;
      typeParameters += genericContext[genericContext.length - i - 1];
      typeSep = ', ';
      var boundRti = boundsRti[i];
      if (isInterestingBound(boundRti)) {
        typeParameters +=
            ' extends ' + runtimeTypeToStringV2(boundRti, genericContext);
      }
    }
    typeParameters += '>';
  }

  String returnTypeText;
  String voidTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_VOID_RETURN_TAG);
  if (JS('bool', '!!#[#]', rti, voidTag)) {
    returnTypeText = 'void';
  } else {
    String returnTypeTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_RETURN_TYPE_TAG);
    var returnRti = JS('', '#[#]', rti, returnTypeTag);
    returnTypeText = runtimeTypeToStringV2(returnRti, genericContext);
  }

  String argumentsText = '';
  String sep = '';

  String requiredParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_REQUIRED_PARAMETERS_TAG);
  if (hasField(rti, requiredParamsTag)) {
    List arguments = JS('JSFixedArray', '#[#]', rti, requiredParamsTag);
    for (var argument in arguments) {
      argumentsText += sep;
      argumentsText += runtimeTypeToStringV2(argument, genericContext);
      sep = ', ';
    }
  }

  String optionalParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_OPTIONAL_PARAMETERS_TAG);
  bool hasOptionalArguments = JS('bool', '# in #', optionalParamsTag, rti);
  if (hasOptionalArguments) {
    List optionalArguments = JS('JSFixedArray', '#[#]', rti, optionalParamsTag);
    argumentsText += '$sep[';
    sep = '';
    for (var argument in optionalArguments) {
      argumentsText += sep;
      argumentsText += runtimeTypeToStringV2(argument, genericContext);
      sep = ', ';
    }
    argumentsText += ']';
  }

  String namedParamsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_NAMED_PARAMETERS_TAG);
  bool hasNamedArguments = JS('bool', '# in #', namedParamsTag, rti);
  if (hasNamedArguments) {
    var namedArguments = JS('', '#[#]', rti, namedParamsTag);
    argumentsText += '$sep{';
    sep = '';
    for (String name in extractKeys(namedArguments)) {
      argumentsText += sep;
      argumentsText += runtimeTypeToStringV2(
          JS('', '#[#]', namedArguments, name), genericContext);
      argumentsText += ' $name';
      sep = ', ';
    }
    argumentsText += '}';
  }

  if (outerContextLength != null) {
    // Pop all of the generic type parameters.
    JS('', '#.length = #', genericContext, outerContextLength);
  }

  // TODO(sra): Below is the same format as the VM. Change to:
  //
  //     return '${returnTypeText} Function${typeParameters}(${argumentsText})';
  //
  return '${typeParameters}(${argumentsText}) => ${returnTypeText}';
}

/**
 * Creates a comma-separated string of human-readable representations of the
 * type representations in the JavaScript array [types] starting at index
 * [startIndex].
 */
String joinArguments(var types, int startIndex) {
  return JS_GET_FLAG('STRONG_MODE')
      ? joinArgumentsV2(types, startIndex, null)
      : joinArgumentsV1(types, startIndex);
}

String joinArgumentsV1(var types, int startIndex,
    {String onTypeVariable(int i)}) {
  if (types == null) return '';
  assert(isJsArray(types));
  bool firstArgument = true;
  bool allDynamic = true;
  StringBuffer buffer = new StringBuffer('');
  for (int index = startIndex; index < getLength(types); index++) {
    if (firstArgument) {
      firstArgument = false;
    } else {
      buffer.write(', ');
    }
    var argument = getIndex(types, index);
    if (argument != null) {
      allDynamic = false;
    }
    buffer
        .write(runtimeTypeToStringV1(argument, onTypeVariable: onTypeVariable));
  }
  return allDynamic ? '' : '<$buffer>';
}

String joinArgumentsV2(var types, int startIndex, List<String> genericContext) {
  if (types == null) return '';
  assert(isJsArray(types));
  bool firstArgument = true;
  bool allDynamic = true;
  StringBuffer buffer = new StringBuffer('');
  for (int index = startIndex; index < getLength(types); index++) {
    if (firstArgument) {
      firstArgument = false;
    } else {
      buffer.write(', ');
    }
    var argument = getIndex(types, index);
    if (argument != null) {
      allDynamic = false;
    }
    buffer.write(runtimeTypeToStringV2(argument, genericContext));
  }
  return allDynamic ? '' : '<$buffer>';
}

/**
 * Returns a human-readable representation of the type of [object].
 *
 * In minified mode does *not* use unminified identifiers (even when present).
 */
String getRuntimeTypeString(var object) {
  if (object is Closure) {
    // This excludes classes that implement Function via a `call` method, but
    // includes classes generated to represent closures in closure conversion.
    var functionRti = extractFunctionTypeObjectFrom(object);
    if (functionRti != null) {
      return runtimeTypeToString(functionRti);
    }
  }
  String className = getClassName(object);
  if (object == null) return className;
  String rtiName = JS_GET_NAME(JsGetName.RTI_NAME);
  var rti = JS('var', r'#[#]', object, rtiName);
  return "$className${joinArguments(rti, 0)}";
}

Type getRuntimeType(var object) {
  String type = getRuntimeTypeString(object);
  return new TypeImpl(type);
}

/**
 * Applies the [substitution] on the [arguments].
 *
 * See the comment in the beginning of this file for a description of the
 * possible values for [substitution].
 */
substitute(var substitution, var arguments) {
  if (substitution == null) return arguments;
  assert(isJsFunction(substitution));
  assert(arguments == null || isJsArray(arguments));
  substitution = invoke(substitution, arguments);
  if (substitution == null) return null;
  if (isJsArray(substitution)) {
    // Substitutions are generated too late to mark Array as used, so use a
    // tautological JS 'cast' to mark Array as used. This is needed only in
    // some tiny tests where the substition is the only thing that creates an
    // Array.
    return JS('JSArray', '#', substitution);
  }
  if (isJsFunction(substitution)) {
    // TODO(johnniwinther): Check if this is still needed.
    return invoke(substitution, arguments);
  }
  return arguments;
}

/**
 * Perform a type check with arguments on the Dart object [object].
 *
 * Parameters:
 * - [isField]: the name of the flag/function to check if the object
 *   is of the correct class.
 * - [checks]: the (JavaScript) list of type representations for the
 *   arguments to check against.
 * - [asField]: the name of the function that transforms the type
 *   arguments of [objects] to an instance of the class that we check
 *   against.
 */
bool checkSubtype(Object object, String isField, List checks, String asField) {
  return JS_GET_FLAG('STRONG_MODE')
      ? checkSubtypeV2(object, isField, checks, asField)
      : checkSubtypeV1(object, isField, checks, asField);
}

bool checkSubtypeV1(
    Object object, String isField, List checks, String asField) {
  if (object == null) return false;
  var arguments = getRuntimeTypeInfo(object);
  // Interceptor is needed for JSArray and native classes.
  // TODO(sra): It could be a more specialized interceptor since [object] is not
  // `null` or a primitive.
  // TODO(9586): Move type info for static functions onto an interceptor.
  var interceptor = getInterceptor(object);
  var isSubclass = getField(interceptor, isField);
  // When we read the field and it is not there, [isSubclass] will be `null`.
  if (isSubclass == null) return false;
  // Should the asField function be passed the receiver?
  var substitution = getField(interceptor, asField);
  return checkArgumentsV1(substitution, arguments, checks);
}

bool checkSubtypeV2(
    Object object, String isField, List checks, String asField) {
  if (object == null) return false;
  var arguments = getRuntimeTypeInfo(object);
  // Interceptor is needed for JSArray and native classes.
  // TODO(sra): It could be a more specialized interceptor since [object] is not
  // `null` or a primitive.
  // TODO(9586): Move type info for static functions onto an interceptor.
  var interceptor = getInterceptor(object);
  var isSubclass = getField(interceptor, isField);
  // When we read the field and it is not there, [isSubclass] will be `null`.
  if (isSubclass == null) return false;
  // Should the asField function be passed the receiver?
  var substitution = getField(interceptor, asField);
  return checkArgumentsV2(substitution, arguments, null, checks, null);
}

/// Returns the field's type name.
///
/// In minified mode, uses the unminified names if available.
String computeTypeName(String isField, List arguments) {
  // Extract the class name from the is field and append the textual
  // representation of the type arguments.
  return Primitives.formatType(
      isCheckPropertyToJsConstructorName(isField), arguments);
}

/// Called from generated code.
Object subtypeCast(Object object, String isField, List checks, String asField) {
  if (object == null) return object;
  if (checkSubtype(object, isField, checks, asField)) return object;
  String typeName = computeTypeName(isField, checks);
  throw new CastErrorImplementation(object, typeName);
}

/// Called from generated code.
Object assertSubtype(
    Object object, String isField, List checks, String asField) {
  if (object == null) return object;
  if (checkSubtype(object, isField, checks, asField)) return object;
  String typeName = computeTypeName(isField, checks);
  throw new TypeErrorImplementation(object, typeName);
}

/// Checks that the type represented by [subtype] is a subtype of [supertype].
/// If not a type error with [message] is thrown.
///
/// Called from generated code.
assertIsSubtype(var subtype, var supertype, String message) {
  if (!isSubtype(subtype, supertype)) {
    throwTypeError(message);
  }
}

throwTypeError(message) {
  throw new TypeErrorImplementation.fromMessage(message);
}

/**
 * Check that the types in the list [arguments] are subtypes of the types in
 * list [checks] (at the respective positions), possibly applying [substitution]
 * to the arguments before the check.
 *
 * See the comment in the beginning of this file for a description of the
 * possible values for [substitution].
 */
bool checkArgumentsV1(var substitution, var arguments, var checks) {
  return areSubtypesV1(substitute(substitution, arguments), checks);
}

bool checkArgumentsV2(
    var substitution, var arguments, var sEnv, var checks, var tEnv) {
  return areSubtypesV2(substitute(substitution, arguments), sEnv, checks, tEnv);
}

/**
 * Checks whether the types of [s] are all subtypes of the types of [t].
 *
 * [s] and [t] are either `null` or JavaScript arrays of type representations,
 * A `null` argument is interpreted as the arguments of a raw type, that is a
 * list of `dynamic`. If [s] and [t] are JavaScript arrays they must be of the
 * same length.
 *
 * See the comment in the beginning of this file for a description of type
 * representations.
 */

bool areSubtypesV1(var s, var t) {
  // `null` means a raw type.
  if (s == null || t == null) return true;

  assert(isJsArray(s));
  assert(isJsArray(t));
  assert(getLength(s) == getLength(t));

  int len = getLength(s);
  for (int i = 0; i < len; i++) {
    if (!isSubtypeV1(getIndex(s, i), getIndex(t, i))) {
      return false;
    }
  }
  return true;
}

bool areSubtypesV2(var s, var sEnv, var t, var tEnv) {
  // `null` means a raw type.
  if (t == null) return true;
  if (s == null) {
    int len = getLength(t);
    for (int i = 0; i < len; i++) {
      if (!isSubtypeV2(null, null, getIndex(t, i), tEnv)) {
        return false;
      }
    }
    return true;
  }

  assert(isJsArray(s));
  assert(isJsArray(t));
  assert(getLength(s) == getLength(t));

  int len = getLength(s);
  for (int i = 0; i < len; i++) {
    if (!isSubtypeV2(getIndex(s, i), sEnv, getIndex(t, i), tEnv)) {
      return false;
    }
  }
  return true;
}

/**
 * Computes the signature by applying the type arguments of [context] as an
 * instance of [contextName] to the signature function [signature].
 */
computeSignature(var signature, var context, var contextName) {
  var typeArguments = getRuntimeTypeArguments(context, contextName);
  return invokeOn(signature, context, typeArguments);
}

/**
 * Returns `true` if the runtime type representation [type] is a supertype of
 * [Null].
 */
bool isSupertypeOfNull(var type) {
  // `null` means `dynamic`.
  return type == null || isDartObjectTypeRti(type) || isNullTypeRti(type);
}

/**
 * Tests whether the Dart object [o] is a subtype of the runtime type
 * representation [t].
 *
 * See the comment in the beginning of this file for a description of type
 * representations.
 */
bool checkSubtypeOfRuntimeType(o, t) {
  if (o == null) return isSupertypeOfNull(t);
  if (t == null) return true;
  // Get the runtime type information from the object here, because we may
  // overwrite o with the interceptor below.
  var rti = getRuntimeTypeInfo(o);
  o = getInterceptor(o);
  var type = getRawRuntimeType(o);
  if (rti != null) {
    // If the type has type variables (that is, `rti != null`), make a copy of
    // the type arguments and insert [o] in the first position to create a
    // compound type representation.
    rti = JS('JSExtendableArray', '#.slice()', rti); // Make a copy.
    JS('', '#.splice(0, 0, #)', rti, type); // Insert type at position 0.
    type = rti;
  }
  if (isDartFunctionType(t)) {
    // Functions are treated specially and have their type information stored
    // directly in the instance.
    var targetSignatureFunction =
        getField(o, '${JS_GET_NAME(JsGetName.SIGNATURE_NAME)}');
    if (targetSignatureFunction == null) return false;
    type = invokeOn(targetSignatureFunction, o, null);
    return isFunctionSubtype(type, t);
  }
  return isSubtype(type, t);
}

/// Called from generated code.
Object subtypeOfRuntimeTypeCast(Object object, var type) {
  if (object != null && !checkSubtypeOfRuntimeType(object, type)) {
    throw new CastErrorImplementation(object, runtimeTypeToString(type));
  }
  return object;
}

/// Called from generated code.
Object assertSubtypeOfRuntimeType(Object object, var type) {
  if (object != null && !checkSubtypeOfRuntimeType(object, type)) {
    throw new TypeErrorImplementation(object, runtimeTypeToString(type));
  }
  return object;
}

/**
 * Extracts the type arguments from a type representation. The result is a
 * JavaScript array or `null`.
 */
getArguments(var type) {
  return isJsArray(type) ? JS('var', r'#.slice(1)', type) : null;
}

/**
 * Checks whether the type represented by the type representation [s] is a
 * subtype of the type represented by the type representation [t].
 *
 * See the comment in the beginning of this file for a description of type
 * representations.
 *
 * The arguments [s] and [t] must be types, usually represented by the
 * constructor of the class, or an array (for generic class types).
 */
bool isSubtype(var s, var t) {
  return JS_GET_FLAG('STRONG_MODE')
      ? isSubtypeV2(s, null, t, null)
      : isSubtypeV1(s, t);
}

bool isSubtypeV1(var s, var t) {
  // Subtyping is reflexive.
  if (isIdentical(s, t)) return true;
  // If either type is dynamic, [s] is a subtype of [t].
  if (s == null || t == null) return true;

  // Generic function type parameters must match exactly, which would have
  // exited earlier. The de Bruijn indexing ensures the representation as a
  // small number can be used for type comparison.
  if (isGenericFunctionTypeParameter(s)) {
    // TODO(sra):  tau <: Object.
    return false;
  }
  if (isGenericFunctionTypeParameter(t)) return false;

  if (isNullType(s)) return true;

  if (isDartFunctionType(t)) {
    return isFunctionSubtypeV1(s, t);
  }
  // Check function types against the Function class and the Object class.
  if (isDartFunctionType(s)) {
    return isDartFunctionTypeRti(t) || isDartObjectTypeRti(t);
  }

  // Get the object describing the class and check for the subtyping flag
  // constructed from the type of [t].
  var typeOfS = isJsArray(s) ? getIndex(s, 0) : s;
  var typeOfT = isJsArray(t) ? getIndex(t, 0) : t;

  // Check for a subtyping flag.
  // Get the necessary substitution of the type arguments, if there is one.
  var substitution;
  if (isNotIdentical(typeOfT, typeOfS)) {
    String typeOfTString = runtimeTypeToString(typeOfT);
    if (!builtinIsSubtype(typeOfS, typeOfTString)) {
      return false;
    }
    var typeOfSPrototype = JS('', '#.prototype', typeOfS);
    var field = '${JS_GET_NAME(JsGetName.OPERATOR_AS_PREFIX)}${typeOfTString}';
    substitution = getField(typeOfSPrototype, field);
  }
  // The class of [s] is a subclass of the class of [t].  If [s] has no type
  // arguments and no substitution, it is used as raw type.  If [t] has no
  // type arguments, it used as a raw type.  In both cases, [s] is a subtype
  // of [t].
  if ((!isJsArray(s) && substitution == null) || !isJsArray(t)) {
    return true;
  }
  // Recursively check the type arguments.
  return checkArgumentsV1(substitution, getArguments(s), getArguments(t));
}

bool isSubtypeV2(var s, var sEnv, var t, var tEnv) {
  // Subtyping is reflexive.
  if (isIdentical(s, t)) return true;

  // [t] is a top type?
  if (t == null) return true;
  if (isDartObjectTypeRti(t)) return true;
  // TODO(sra): void is a top type.

  // [s] is a top type?
  if (s == null) return false;

  // Generic function type parameters must match exactly, which would have
  // exited earlier. The de Bruijn indexing ensures the representation as a
  // small number can be used for type comparison.
  if (isGenericFunctionTypeParameter(s)) {
    // TODO(sra): Use the bound of the type variable.
    return false;
  }
  if (isGenericFunctionTypeParameter(t)) return false;

  if (isNullType(s)) return true;

  if (isDartFunctionType(t)) {
    return isFunctionSubtypeV2(s, sEnv, t, tEnv);
  }

  if (isDartFunctionType(s)) {
    // Check function types against the `Function` class (`Object` is also a
    // supertype, but is tested above with other 'top' types.).
    return isDartFunctionTypeRti(t);
  }

  // Get the object describing the class and check for the subtyping flag
  // constructed from the type of [t].
  var typeOfS = isJsArray(s) ? getIndex(s, 0) : s;
  var typeOfT = isJsArray(t) ? getIndex(t, 0) : t;

  // Check for a subtyping flag.
  // Get the necessary substitution of the type arguments, if there is one.
  var substitution;
  if (isNotIdentical(typeOfT, typeOfS)) {
    String typeOfTString = runtimeTypeToString(typeOfT);
    if (!builtinIsSubtype(typeOfS, typeOfTString)) {
      return false;
    }
    var typeOfSPrototype = JS('', '#.prototype', typeOfS);
    var field = '${JS_GET_NAME(JsGetName.OPERATOR_AS_PREFIX)}${typeOfTString}';
    substitution = getField(typeOfSPrototype, field);
  }
  // The class of [s] is a subclass of the class of [t].  If [s] has no type
  // arguments and no substitution, it is used as raw type.  If [t] has no
  // type arguments, it used as a raw type.  In both cases, [s] is a subtype
  // of [t].
  if ((!isJsArray(s) && substitution == null) || !isJsArray(t)) {
    return true;
  }
  // Recursively check the type arguments.
  return checkArgumentsV2(
      substitution, getArguments(s), sEnv, getArguments(t), tEnv);
}

bool isAssignableV1(var s, var t) {
  return isSubtypeV1(s, t) || isSubtypeV1(t, s);
}

/**
 * If [allowShorter] is `true`, [t] is allowed to be shorter than [s].
 */
bool areAssignableV1(List s, List t, bool allowShorter) {
  // Both lists are empty and thus equal.
  if (t == null && s == null) return true;
  // [t] is empty (and [s] is not) => only OK if [allowShorter].
  if (t == null) return allowShorter;
  // [s] is empty (and [t] is not) => [s] is not longer or equal to [t].
  if (s == null) return false;

  assert(isJsArray(s));
  assert(isJsArray(t));

  int sLength = getLength(s);
  int tLength = getLength(t);
  if (allowShorter) {
    if (sLength < tLength) return false;
  } else {
    if (sLength != tLength) return false;
  }

  for (int i = 0; i < tLength; i++) {
    if (!isAssignableV1(getIndex(s, i), getIndex(t, i))) {
      return false;
    }
  }
  return true;
}

bool areAssignableMapsV1(var s, var t) {
  if (t == null) return true;
  if (s == null) return false;

  assert(isJsObject(s));
  assert(isJsObject(t));

  List names =
      JSArray.markFixedList(JS('', 'Object.getOwnPropertyNames(#)', t));
  for (int i = 0; i < names.length; i++) {
    var name = names[i];
    if (JS('bool', '!Object.hasOwnProperty.call(#, #)', s, name)) {
      return false;
    }
    var tType = JS('', '#[#]', t, name);
    var sType = JS('', '#[#]', s, name);
    if (!isAssignableV1(tType, sType)) return false;
  }
  return true;
}

/// Top-level function subtype check when [t] is known to be a function type
/// rti.
bool isFunctionSubtype(var s, var t) {
  return JS_GET_FLAG('STRONG_MODE')
      ? isFunctionSubtypeV2(s, null, t, null)
      : isFunctionSubtypeV1(s, t);
}

bool isFunctionSubtypeV1(var s, var t) {
  assert(isDartFunctionType(t));
  if (!isDartFunctionType(s)) return false;
  var genericBoundsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_GENERIC_BOUNDS_TAG);
  var voidReturnTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_VOID_RETURN_TAG);
  var returnTypeTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_RETURN_TYPE_TAG);

  if (hasField(s, voidReturnTag)) {
    if (hasNoField(t, voidReturnTag) && hasField(t, returnTypeTag)) {
      return false;
    }
  } else if (hasNoField(t, voidReturnTag)) {
    var sReturnType = getField(s, returnTypeTag);
    var tReturnType = getField(t, returnTypeTag);
    if (!isAssignableV1(sReturnType, tReturnType)) return false;
  }
  var requiredParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_REQUIRED_PARAMETERS_TAG);
  var sParameterTypes = getField(s, requiredParametersTag);
  var tParameterTypes = getField(t, requiredParametersTag);

  var optionalParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_OPTIONAL_PARAMETERS_TAG);
  var sOptionalParameterTypes = getField(s, optionalParametersTag);
  var tOptionalParameterTypes = getField(t, optionalParametersTag);

  int sParametersLen = sParameterTypes != null ? getLength(sParameterTypes) : 0;
  int tParametersLen = tParameterTypes != null ? getLength(tParameterTypes) : 0;

  int sOptionalParametersLen =
      sOptionalParameterTypes != null ? getLength(sOptionalParameterTypes) : 0;
  int tOptionalParametersLen =
      tOptionalParameterTypes != null ? getLength(tOptionalParameterTypes) : 0;

  if (sParametersLen > tParametersLen) {
    // Too many required parameters in [s].
    return false;
  }
  if (sParametersLen + sOptionalParametersLen <
      tParametersLen + tOptionalParametersLen) {
    // Too few required and optional parameters in [s].
    return false;
  }
  if (sParametersLen == tParametersLen) {
    // Simple case: Same number of required parameters.
    if (!areAssignableV1(sParameterTypes, tParameterTypes, false)) return false;
    if (!areAssignableV1(
        sOptionalParameterTypes, tOptionalParameterTypes, true)) {
      return false;
    }
  } else {
    // Complex case: Optional parameters of [s] for required parameters of [t].
    int pos = 0;
    // Check all required parameters of [s].
    for (; pos < sParametersLen; pos++) {
      if (!isAssignableV1(
          getIndex(sParameterTypes, pos), getIndex(tParameterTypes, pos))) {
        return false;
      }
    }
    int sPos = 0;
    int tPos = pos;
    // Check the remaining parameters of [t] with the first optional parameters
    // of [s].
    for (; tPos < tParametersLen; sPos++, tPos++) {
      if (!isAssignableV1(getIndex(sOptionalParameterTypes, sPos),
          getIndex(tParameterTypes, tPos))) {
        return false;
      }
    }
    tPos = 0;
    // Check the optional parameters of [t] with the remaining optional
    // parameters of [s]:
    for (; tPos < tOptionalParametersLen; sPos++, tPos++) {
      if (!isAssignableV1(getIndex(sOptionalParameterTypes, sPos),
          getIndex(tOptionalParameterTypes, tPos))) {
        return false;
      }
    }
  }

  var namedParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_NAMED_PARAMETERS_TAG);
  var sNamedParameters = getField(s, namedParametersTag);
  var tNamedParameters = getField(t, namedParametersTag);
  return areAssignableMapsV1(sNamedParameters, tNamedParameters);
}

bool isFunctionSubtypeV2(var s, var sEnv, var t, var tEnv) {
  assert(isDartFunctionType(t));
  if (!isDartFunctionType(s)) return false;
  var genericBoundsTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_GENERIC_BOUNDS_TAG);
  var voidReturnTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_VOID_RETURN_TAG);
  var returnTypeTag = JS_GET_NAME(JsGetName.FUNCTION_TYPE_RETURN_TYPE_TAG);

  // Generic function types must agree on number of type parameters and bounds.
  if (hasField(s, genericBoundsTag)) {
    if (hasNoField(t, genericBoundsTag)) return false;
    var sBounds = getField(s, genericBoundsTag);
    var tBounds = getField(t, genericBoundsTag);
    int sGenericParameters = getLength(sBounds);
    int tGenericParameters = getLength(tBounds);
    if (sGenericParameters != tGenericParameters) return false;
    // TODO(sra): Compare bounds, which should be 'equal' trees due to the de
    // Bruijn numbering of type parameters.
    // TODO(sra): Extend [sEnv] and [tEnv] with bindings for the [s] and [t]
    // type parameters to enable checking the bound against non-type-parameter
    // terms.
  } else if (hasField(t, genericBoundsTag)) {
    return false;
  }

  // 'void' is a top type, so use `null` (dynamic) in its place.
  // TODO(sra): Create a void type that can be used in all positions.
  var sReturnType =
      hasField(s, voidReturnTag) ? null : getField(s, returnTypeTag);
  var tReturnType =
      hasField(t, voidReturnTag) ? null : getField(t, returnTypeTag);
  if (!isSubtypeV2(sReturnType, sEnv, tReturnType, tEnv)) return false;

  var requiredParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_REQUIRED_PARAMETERS_TAG);
  var sParameterTypes = getField(s, requiredParametersTag);
  var tParameterTypes = getField(t, requiredParametersTag);

  var optionalParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_OPTIONAL_PARAMETERS_TAG);
  var sOptionalParameterTypes = getField(s, optionalParametersTag);
  var tOptionalParameterTypes = getField(t, optionalParametersTag);

  int sParametersLen = sParameterTypes != null ? getLength(sParameterTypes) : 0;
  int tParametersLen = tParameterTypes != null ? getLength(tParameterTypes) : 0;

  int sOptionalParametersLen =
      sOptionalParameterTypes != null ? getLength(sOptionalParameterTypes) : 0;
  int tOptionalParametersLen =
      tOptionalParameterTypes != null ? getLength(tOptionalParameterTypes) : 0;

  if (sParametersLen > tParametersLen) {
    // Too many required parameters in [s].
    return false;
  }
  if (sParametersLen + sOptionalParametersLen <
      tParametersLen + tOptionalParametersLen) {
    // Too few required and optional parameters in [s].
    return false;
  }

  int pos = 0;
  // Check all required parameters of [s].
  for (; pos < sParametersLen; pos++) {
    if (!isSubtypeV2(getIndex(tParameterTypes, pos), tEnv,
        getIndex(sParameterTypes, pos), sEnv)) {
      return false;
    }
  }
  int sPos = 0;
  int tPos = pos;
  // Check the remaining parameters of [t] with the first optional parameters
  // of [s].
  for (; tPos < tParametersLen; sPos++, tPos++) {
    if (!isSubtypeV2(getIndex(tOptionalParameterTypes, tPos), tEnv,
        getIndex(sParameterTypes, sPos), sEnv)) {
      return false;
    }
  }
  tPos = 0;
  // Check the optional parameters of [t] with the remaining optional
  // parameters of [s]:
  for (; tPos < tOptionalParametersLen; sPos++, tPos++) {
    if (!isSubtypeV2(getIndex(tOptionalParameterTypes, tPos), tEnv,
        getIndex(sOptionalParameterTypes, sPos), sEnv)) {
      return false;
    }
  }

  var namedParametersTag =
      JS_GET_NAME(JsGetName.FUNCTION_TYPE_NAMED_PARAMETERS_TAG);
  var sNamedParameters = getField(s, namedParametersTag);
  var tNamedParameters = getField(t, namedParametersTag);
  if (tNamedParameters == null) return true;
  if (sNamedParameters == null) return false;
  return namedParametersSubtypeCheckV2(
      sNamedParameters, sEnv, tNamedParameters, tEnv);
}

bool namedParametersSubtypeCheckV2(var s, var sEnv, var t, var tEnv) {
  assert(isJsObject(s));
  assert(isJsObject(t));

  // Each named parameter in [t] must exist in [s] and be a subtype of the type
  // in [s].
  List names = JS('JSFixedArray', 'Object.getOwnPropertyNames(#)', t);
  for (int i = 0; i < names.length; i++) {
    var name = names[i];
    if (JS('bool', '!Object.hasOwnProperty.call(#, #)', s, name)) {
      return false;
    }
    var tType = JS('', '#[#]', t, name);
    var sType = JS('', '#[#]', s, name);
    if (!isSubtypeV2(tType, tEnv, sType, sEnv)) return false;
  }
  return true;
}

/**
 * Returns whether [type] is the representation of a generic function type
 * parameter. Generic function type parameters are represented de Bruijn
 * indexes.
 */
bool isGenericFunctionTypeParameter(var type) {
  return type is num; // Actually int, but 'is num' is faster.
}

/**
 * Calls the JavaScript [function] with the [arguments] with the global scope
 * as the `this` context.
 */
invoke(var function, var arguments) => invokeOn(function, null, arguments);

/**
 * Calls the JavaScript [function] with the [arguments] with [receiver] as the
 * `this` context.
 */
Object invokeOn(function, receiver, arguments) {
  assert(isJsFunction(function));
  assert(arguments == null || isJsArray(arguments));
  return JS('var', r'#.apply(#, #)', function, receiver, arguments);
}

/// Calls the property [name] on the JavaScript [object].
call(var object, String name) => JS('var', r'#[#]()', object, name);

/// Returns the property [name] of the JavaScript object [object].
getField(var object, String name) => JS('var', r'#[#]', object, name);

/// Returns the property [index] of the JavaScript array [array].
getIndex(var array, int index) {
  assert(isJsArray(array));
  return JS('var', r'#[#]', array, index);
}

/// Returns the length of the JavaScript array [array].
int getLength(var array) {
  assert(isJsArray(array));
  return JS('int', r'#.length', array);
}

/// Returns whether [value] is a JavaScript array.
bool isJsArray(var value) {
  return value is JSArray;
}

hasField(var object, var name) => JS('bool', r'# in #', name, object);

hasNoField(var object, var name) => !hasField(object, name);

/// Returns `true` if [o] is a JavaScript function.
bool isJsFunction(var o) => JS('bool', r'typeof # == "function"', o);

/// Returns `true` if [o] is a JavaScript object.
bool isJsObject(var o) => JS('bool', r"typeof # == 'object'", o);

/**
 * Returns `true` if the JavaScript values [s] and [t] are identical. We use
 * this helper instead of [identical] because `identical` needs to merge
 * `null` and `undefined` (which we can avoid).
 */
bool isIdentical(var s, var t) => JS('bool', '# === #', s, t);

/**
 * Returns `true` if the JavaScript values [s] and [t] are not identical. We use
 * this helper instead of [identical] because `identical` needs to merge
 * `null` and `undefined` (which we can avoid).
 */
bool isNotIdentical(var s, var t) => JS('bool', '# !== #', s, t);

/// 'Top' bounds are uninteresting: null/undefined and Object.
bool isInterestingBound(rti) =>
    rti != null &&
    isNotIdentical(
        rti,
        JS_BUILTIN(
            'depends:none;effects:none;', JsBuiltin.dartObjectConstructor));
