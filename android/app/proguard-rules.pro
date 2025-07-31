# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# Keep Flutter classes
-keep class io.flutter.** { *; }
-keep class androidx.** { *; }

# Keep audio-related classes
-keep class com.ryanheise.** { *; }
-keep class com.google.android.exoplayer2.** { *; }

# Keep HTTP classes
-keep class okhttp3.** { *; }
-keep class retrofit2.** { *; }

# Keep TTS classes
-keep class android.speech.tts.** { *; }

# Keep permission handler classes
-keep class com.baseflow.permissionhandler.** { *; }

# Keep path provider classes
-keep class io.flutter.plugins.pathprovider.** { *; }