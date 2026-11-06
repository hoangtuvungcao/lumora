# lumora-bot (JavaScript / Node.js)

Build bots for the [Lumora](https://getlumora.pages.dev/) messenger. A bot is a normal Lumora account
run by your code through **Lumora Bot Runner** (`lumorad`): users add it by its ID or `@name·tag`,
messages are end-to-end encrypted, and there is no server to rent.

```bash
npm install ./sdk/js                          # from a checkout of the Lumora repository
npm install https://getlumora.pages.dev/developers/packages/lumora-bot-1.1.0.tgz
```

One ES module with no dependencies (`lumora-bot.mjs`, Node.js 18+) plus TypeScript types (`lumora-bot.d.ts`).

```js
import { Bot } from "lumora-bot";

const bot = new Bot();                        // token from $LUMORA_BOT_TOKEN (BotFather in the app)

bot.command("start", "Start", (ctx) => ctx.reply("Hi! Pick one:", [[{ text: "👍 Like", data: "like" }]]));
bot.onCallback({ data: "like" }, (ctx) => ctx.edit("Thanks! 👍"));

await bot.run();
```

```bash
export LUMORA_BOT_TOKEN="lumora_bot_..."      # from @BotFather in the Lumora app
export LUMORAD=/path/to/lumorad               # Lumora Bot Runner
node bot.mjs
```

Guides, the full API reference and deployment notes: <https://getlumora.pages.dev/developers/>.

License: MIT (see LICENSE). Changes: CHANGELOG.md.
