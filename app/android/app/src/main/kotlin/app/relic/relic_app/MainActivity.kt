package app.relic.relic_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "Save to device" -> the real public Downloads collection. See SaveChannel.
        SaveChannel.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
