# Local bot secrets

Files ending in `.env` in this directory are local-only and ignored by git.

Create one env file per bot:

```sh
cp secrets/nfi-major.env.example secrets/nfi-major.env
cp secrets/nfi-mid.env.example secrets/nfi-mid.env
cp secrets/nfi-alt.env.example secrets/nfi-alt.env
cp secrets/nfi-defi.env.example secrets/nfi-defi.env
# cp secrets/nfi-meme.env.example secrets/nfi-meme.env
```

Then replace every `CHANGE_ME_*` value in the copied files.

Use different Binance API keys, Telegram bots/chat IDs, API usernames, API passwords, JWT secrets, and WS tokens for each bot.

You can generate random API secrets with:

```sh
openssl rand -hex 32
```
