// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub.pub_package_provider;

import 'dart:async';
import 'dart:io';

import 'package:barback/barback.dart';
import 'package:path/path.dart' as path;

import '../io.dart';
import '../package_graph.dart';
import '../preprocess.dart';
import '../sdk.dart' as sdk;
import '../utils.dart';

/// The path to the lib directory of the compiler_unsupported package used by
/// pub.
///
/// This is used to make sure dart2js is running against its own version of its
/// internal libraries when running from the pub repo. It's `null` if we're
/// running from the Dart repo or from the built SDK.
final _compilerUnsupportedLib = (() {
  if (runningFromSdk) return null;
  if (runningFromDartRepo) return null;

  // TODO(nweiz): When we switch over to ".packages", read the path from there
  // instead, or from the resource API if it's usable by that point.
  return path.join(pubRoot, 'packages', 'compiler_unsupported');
})();

final _zlib = new ZLibCodec();

/// An implementation of barback's [PackageProvider] interface so that barback
/// can find assets within pub packages.
class PubPackageProvider implements StaticPackageProvider {
  final PackageGraph _graph;
  final List<String> staticPackages;

  Iterable<String> get packages =>
      _graph.packages.keys.toSet().difference(staticPackages.toSet());

  PubPackageProvider(PackageGraph graph)
      : _graph = graph,
        staticPackages = [r"$pub", r"$sdk"]..addAll(
            graph.packages.keys.where(graph.isPackageStatic));

  Future<Asset> getAsset(AssetId id) async {
    // "$pub" is a psuedo-package that allows pub's transformer-loading
    // infrastructure to share code with pub proper.
    if (id.package == r'$pub') {
      var components = path.url.split(id.path);
      assert(components.isNotEmpty);
      assert(components.first == 'lib');
      components[0] = 'dart';
      var file = assetPath(path.joinAll(components));
      _assertExists(file, id);

      // Barback may not be in the package graph if there are no user-defined
      // transformers being used at all. The "$pub" sources are still provided,
      // but will never be loaded.
      if (!_graph.packages.containsKey("barback")) {
        return new Asset.fromPath(id, file);
      }

      var versions = mapMap(_graph.packages,
          value: (_, package) => package.version);
      var contents = readTextFile(file);
      contents = preprocess(contents, versions, path.toUri(file));
      return new Asset.fromString(id, contents);
    }

    // "$sdk" is a pseudo-package that provides access to the Dart library
    // sources in the SDK. The dart2js transformer uses this to locate the Dart
    // sources for "dart:" libraries.
    if (id.package == r'$sdk') {
      // The asset path contains two "lib" entries. The first represents pub's
      // concept that all public assets are in "lib". The second comes from the
      // organization of the SDK itself. Strip off the first. Leave the second
      // since dart2js adds it and expects it to be there.
      var parts = path.split(path.fromUri(id.path));
      assert(parts.isNotEmpty && parts[0] == 'lib');
      parts = parts.skip(1).toList();

      if (_compilerUnsupportedLib == null) {
        var file = path.join(sdk.rootDirectory, path.joinAll(parts));
        _assertExists(file, id);
        return new Asset.fromPath(id, file);
      }

      // If we're running from pub's repo, our version of dart2js comes from
      // compiler_unsupported and may expect different SDK sources than the
      // actual SDK we're using. Handily, compiler_unsupported contains a full
      // (ZLib-encoded) copy of the SDK, so we load sources from that instead.
      var file = path.join(_compilerUnsupportedLib, 'sdk',
          path.joinAll(parts.skip(1))) + "_";
      _assertExists(file, id);
      return new Asset.fromStream(id, callbackStream(() =>
          _zlib.decoder.bind(new File(file).openRead())));
    }

    var nativePath = path.fromUri(id.path);
    var file = _graph.packages[id.package].path(nativePath);
    _assertExists(file, id);
    return new Asset.fromPath(id, file);
  }

  /// Throw an [AssetNotFoundException] for [id] if [path] doesn't exist.
  void _assertExists(String path, AssetId id) {
    if (!fileExists(path)) throw new AssetNotFoundException(id);
  }

  Stream<AssetId> getAllAssetIds(String packageName) {
    if (packageName == r'$pub') {
      // "$pub" is a pseudo-package that allows pub's transformer-loading
      // infrastructure to share code with pub proper. We provide it only during
      // the initial transformer loading process.
      var dartPath = assetPath('dart');
      return new Stream.fromIterable(listDir(dartPath, recursive: true)
          // Don't include directories.
          .where((file) => path.extension(file) == ".dart")
          .map((library) {
        var idPath = path.join('lib', path.relative(library, from: dartPath));
        return new AssetId('\$pub', path.toUri(idPath).toString());
      }));
    } else if (packageName == r'$sdk') {
      // "$sdk" is a pseudo-package that allows the dart2js transformer to find
      // the Dart core libraries without hitting the file system directly. This
      // ensures they work with source maps.
      var libPath = _compilerUnsupportedLib == null
          ? path.join(sdk.rootDirectory, "lib")
          : path.join(_compilerUnsupportedLib, "sdk");
      var files = listDir(libPath, recursive: true);

      if (_compilerUnsupportedLib != null) {
        // compiler_unsupported's SDK sources are ZLib-encoded; to indicate
        // this, they end in "_". We serve them decoded, though, so we strip the
        // underscore to get the asset paths.
        var trailingUnderscore = new RegExp(r"_$");
        files = files.map((file) => file.replaceAll(trailingUnderscore, ""));
      }

      return new Stream.fromIterable(files
          .where((file) => path.extension(file) == ".dart")
          .map((file) {
        var idPath = path.join("lib", "lib",
            path.relative(file, from: libPath));
        return new AssetId('\$sdk', path.toUri(idPath).toString());
      }));
    } else {
      var package = _graph.packages[packageName];
      return new Stream.fromIterable(
          package.listFiles(beneath: 'lib').map((file) {
        return new AssetId(packageName,
            path.toUri(package.relative(file)).toString());
      }));
    }
  }
}
