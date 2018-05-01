// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO(johnniwinther): Remove --omit-implicit-checks when constant
// instantiations are supported.
// dart2jsOptions=--strong --omit-implicit-checks

import '32997a_lib.dart' deferred as b;

main() async {
  await b.loadLibrary();
  print(b.m(3));
}