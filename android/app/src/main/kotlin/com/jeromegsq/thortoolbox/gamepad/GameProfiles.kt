package com.jeromegsq.thortoolbox.gamepad

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Which controller remap belongs to which installed game, plus the running
 * service's own bookkeeping for switching between them live.
 *
 * A game keeps its own rendered profile text — `renderConfig`'s `[glob]`
 * sections, no shortcuts, those stay global — rather than a parsed model:
 * parsing and rendering that text already live in Dart
 * (`lib/src/gamepad/profile.dart`), and duplicating it here would undo the
 * point of that split.
 */
object GameProfiles {

    data class Game(val pkg: String, val label: String, val config: String)

    private const val FILE = "game_profiles"
    private const val K_ENABLED = "enabled"
    private const val K_GAMES = "games"
    private const val K_DEFAULT_SNAPSHOT = "default_snapshot"
    private const val K_CURRENT_TARGET = "current_target"

    private fun sp(c: Context): SharedPreferences = c.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun enabled(c: Context): Boolean = sp(c).getBoolean(K_ENABLED, false)

    fun setEnabled(c: Context, on: Boolean) {
        sp(c).edit().putBoolean(K_ENABLED, on).apply()
    }

    fun games(c: Context): List<Game> {
        val text = sp(c).getString(K_GAMES, null) ?: return emptyList()
        val arr = JSONArray(text)
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Game(o.getString("package"), o.getString("label"), o.optString("config", ""))
        }
    }

    private fun writeGames(c: Context, games: List<Game>) {
        val arr = JSONArray()
        for (g in games) {
            arr.put(JSONObject().put("package", g.pkg).put("label", g.label).put("config", g.config))
        }
        sp(c).edit().putString(K_GAMES, arr.toString()).apply()
    }

    /** Adds a game with an empty profile. Does nothing if it is already there. */
    fun addGame(c: Context, pkg: String, label: String) {
        val games = games(c)
        if (games.any { it.pkg == pkg }) return
        writeGames(c, games + Game(pkg, label, ""))
    }

    fun removeGame(c: Context, pkg: String) {
        writeGames(c, games(c).filterNot { it.pkg == pkg })
        // The game it was watching just went away: fall back to the default
        // rather than keep pushing a profile nothing points to any more.
        if (currentTarget(c) == pkg) setCurrentTarget(c, null)
    }

    fun saveGame(c: Context, pkg: String, config: String) {
        writeGames(c, games(c).map { if (it.pkg == pkg) it.copy(config = config) else it })
    }

    // ---- GameProfileService's own bookkeeping --------------------------

    /** The profile text that was live the last time nothing overrode it. */
    fun defaultSnapshot(c: Context): String? = sp(c).getString(K_DEFAULT_SNAPSHOT, null)

    fun setDefaultSnapshot(c: Context, text: String) {
        sp(c).edit().putString(K_DEFAULT_SNAPSHOT, text).apply()
    }

    /** Package of the game whose profile is currently live, or null for the default. */
    fun currentTarget(c: Context): String? = sp(c).getString(K_CURRENT_TARGET, null)

    fun setCurrentTarget(c: Context, pkg: String?) {
        sp(c).edit().apply {
            if (pkg == null) remove(K_CURRENT_TARGET) else putString(K_CURRENT_TARGET, pkg)
        }.apply()
    }
}
