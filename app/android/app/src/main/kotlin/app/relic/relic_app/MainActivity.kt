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
        stripStaleShare(intent, recreated = savedInstanceState != null)?.let { setIntent(it) }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(stripStaleShare(intent, recreated = false) ?: intent)
    }

    /**
     * Neuter an ACTION_SEND intent that Android is merely REPLAYING.
     *
     * Two replays exist. We are `singleTop`, so opening Relic from the recents
     * screen resumes the existing task and hands the activity back the intent
     * that first started it, flagged LAUNCHED_FROM_HISTORY. And when the system
     * kills the process in the background and later recreates the activity, it
     * rebuilds it with that same original intent, this time with no flag at all
     * but with a saved instance state, which a genuinely new launch never has
     * (a new share while the task exists arrives through onNewIntent instead).
     *
     * In both cases `receive_sharing_intent` sees a share it cannot tell apart
     * from a real one. Sharing something Relic already holds now moves that
     * item to the top, dated now, so a replay that got through would shuffle a
     * days-old screenshot to the top of the list every time the app came back.
     * Dropping the payload here is the fix: the replay stops being a share at
     * all, so nothing is captured, moved, or said.
     *
     * Only ACTION_SEND is touched. A stale VIEW/deep-link intent is a separate
     * question with a separate answer, and rewriting it here would break the
     * quick-settings tile's `relic://capture`.
     *
     * Returns the intent to hand on, or null to leave the caller's own alone.
     */
    private fun stripStaleShare(i: Intent?, recreated: Boolean): Intent? {
        if (i == null) return null
        val fromHistory = i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (!fromHistory && !recreated) return null
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
