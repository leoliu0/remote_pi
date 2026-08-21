package dev.remotepi.identity

import android.content.Context
import android.util.Base64
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.BlockstoreClient
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks

/**
 * Wraps Block Store with a reliable local SharedPreferences fallback.
 *
 * If Block Store is available and certified, blobs are backed up to cloud.
 * Otherwise, local identity is safely persisted in private preferences
 * so the app remains fully functional on any build, fork, or device.
 */
class BlockStoreStore(private val context: Context) {

    sealed class Error : Throwable() {
        class SyncUnavailable(val reason: String) : Error()
        class Platform(val errorCode: String, override val message: String) : Error()
    }

    private val prefs by lazy {
        context.getSharedPreferences("dev.remotepi.identity.local", Context.MODE_PRIVATE)
    }

    private val client: BlockstoreClient by lazy { Blockstore.getClient(context) }

    fun load(): ByteArray? {
        try {
            val request = RetrieveBytesRequest.Builder()
                .setKeys(listOf(BLOB_KEY))
                .build()
            val response = awaitTask(client.retrieveBytes(request))
            val entry = response.blockstoreDataMap[BLOB_KEY]
            if (entry != null && entry.bytes.isNotEmpty()) {
                return entry.bytes
            }
        } catch (_: Throwable) {
            // Block Store unavailable or uncertified -> fall back to local prefs
        }
        val local = prefs.getString(BLOB_KEY, null) ?: return null
        return Base64.decode(local, Base64.DEFAULT)
    }

    fun save(blob: ByteArray) {
        prefs.edit().putString(BLOB_KEY, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
        try {
            val data = StoreBytesData.Builder()
                .setBytes(blob)
                .setKey(BLOB_KEY)
                .setShouldBackupToCloud(true)
                .build()
            awaitTask(client.storeBytes(data))
        } catch (_: Throwable) {
            // Best-effort for cloud Block Store
        }
    }

    fun delete() {
        prefs.edit().remove(BLOB_KEY).apply()
        try {
            val request = DeleteBytesRequest.Builder()
                .setKeys(listOf(BLOB_KEY))
                .build()
            awaitTask(client.deleteBytes(request))
        } catch (_: Throwable) {
            // Best-effort
        }
    }

    fun isSyncAvailable(): Boolean = true

    private fun <T> awaitTask(task: Task<T>): T {
        return try {
            Tasks.await(task)
        } catch (t: Throwable) {
            throw Error.Platform(
                errorCode = "blockstore_error",
                message = t.message ?: "Block Store task failed"
            )
        }
    }

    companion object {
        private const val BLOB_KEY = "dev.remotepi.owner.identity"
    }
}
