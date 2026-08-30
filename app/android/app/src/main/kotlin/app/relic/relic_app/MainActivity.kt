package app.relic.relic_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "Save to device" -> the real public Downloads collection. See SaveChannel.
        SaveChannel.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super: the plugins that read the launch intent are attached
        // from inside FlutterActivity's own onCreate, so this is the last
        // moment we can take the payload away from them.
        stripStaleShare(intent)?.let { setIntent(it) }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(stripStaleShare(intent) ?: intent)
    }

    /**
     * Neuter an ACTION_SEND intent that Android is merely REPLAYING.
     *
     * We are `singleTop`, so opening Relic from the recents screen resumes the
     * existing task and hands the activity back the intent that first started
     * it — flagged LAUNCHED_FROM_HISTORY. When that first launch was a share,
     * `receive_sharing_intent` sees a share it cannot tell apart from a real
     * one and Relic tries to capture, days later, a screenshot the user shared
     * once. `ShareDedup` catches the content and refuses to store it twice, so
     * nothing is duplicated, but the user still opened the app from their
     * launcher and got told "Already in Relic" about something they had not
     * shared. Dropping the payload here is the actual fix: the replay stops
     * being a share at all, so no capture is attempted and nothing is said.
     *
     * Only ACTION_SEND is touched. A stale VIEW/deep-link intent is a separate
     * question with a separate answer, and rewriting it here would break the
     * quick-settings tile's `relic://capture`.
     *
     * Returns the intent to hand on, or null to leave the caller's own alone.
     */
    private fun stripStaleShare(i: Intent?): Intent? {
        if (i == null) return null
        if (i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) return null
        if (i.action != Intent.ACTION_SEND && i.action != Intent.ACTION_SEND_MULTIPLE) {
            return null
        }
        return i.apply {
            action = Intent.ACTION_MAIN
            type = null
            data = null
            removeExtra(Intent.EXTRA_STREAM)
            removeExtra(Intent.EXTRA_TEXT)
        }
    }
}
