package syntaxfacts

class KotlinSyntaxFactsCore(private var status: Status, private val sink: Sink) {
    private var count = 0

    fun process(user: User, items: List<Item>, callback: (Account) -> Unit): String? {
        val name = user.profile?.name
        val account = Account(name, user.active)
        callback(account)

        when (user.role) {
            "owner", "admin" -> escalate(user)
            "guest" -> fallback(user)
            else -> defaultCase(user)
        }

        if (status == Status.IDLE && user.ready) {
            count += 1
            publish(Status.BUSY)
        } else {
            println("not ready")
        }

        for (item in items) {
            item.children()
        }

        return name ?: "missing"
    }

    private fun audit(name: String): Status {
        println(name)
        sink.send("record", name)
        return status
    }

    fun ready(): Boolean {
        return count > 0
    }
}

enum class Status {
    IDLE,
    BUSY
}

