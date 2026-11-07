# lumora-bot (Python)

Build bots for the [Lumora](https://getlumora.pages.dev/) messaging app. A bot is a normal Lumora account
run by your code through **Lumora Bot Runner** (`lumorad`): users add it by its ID or `@name·tag`,
messages are end-to-end encrypted, and there is no server to rent.

```bash
pip install ./sdk/python                      # from a checkout of the Lumora repository
pip install https://getlumora.pages.dev/developers/packages/lumora_bot-1.1.0-py3-none-any.whl
```

The SDK is one file with no dependencies (`lumora_bot.py`, Python 3.8+), so copying it next to your bot works too.

```python
from lumora_bot import Bot

bot = Bot()                                   # token from $LUMORA_BOT_TOKEN (Bot Studio in the app)

@bot.command("start", "Start")
def start(ctx):
    ctx.reply("Hi! Pick one:", buttons=[[("👍 Like", "like")]])

@bot.on_callback(data="like")
def liked(ctx):
    ctx.edit("Thanks! 👍")

bot.run()
```

```bash
export LUMORA_BOT_TOKEN="lumora_bot_..."      # from Bot Studio in the Lumora app
export LUMORAD=/path/to/lumorad               # Lumora Bot Runner
python3 bot.py
```

Guides, the full API reference and deployment notes: <https://getlumora.pages.dev/developers/>.

License: MIT (see LICENSE). Changes: CHANGELOG.md.
