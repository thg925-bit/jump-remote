Vendored copy of flutter_pcm_sound 3.3.3 (public domain, https://github.com/chipweinberger/flutter_pcm_sound).

Only change: `android/build.gradle` compileSdkVersion 33 -> 36. The androidx libraries it
resolves require compiling against 34+, and Gradle won't let the app override a plugin's
compileSdk after the plugin's own script sets it. Drop this copy once upstream bumps it.
