const MAX_EMAIL_BYTES = 14 * 1024 * 1024;
const KV_TTL_SECONDS = 7 * 24 * 60 * 60;
const RETRY_DELAYS = [180, 600, 1800, 3600, 7200, 28800];
const DLQ_NAME = "aliasvault-mail-retry-dlq";

function isPermanentStatus(status) {
  return status === 400 || status === 405 || status === 413 || status === 422;
}

function retryDelay(attempts) {
  const index = Math.min(Math.max(attempts - 1, 0), RETRY_DELAYS.length - 1);
  return RETRY_DELAYS[index];
}

async function postToBridge(raw, from, to, env) {
  const response = await fetch(env.INBOUND_URL, {
    method: "POST",
    headers: {
      "content-type": "message/rfc822",
      "x-webhook-secret": env.WEBHOOK_SECRET,
      "x-mail-from": from,
      "x-mail-to": to,
    },
    body: raw,
  });
  const text = await response.text();
  return { ok: response.ok, status: response.status, text };
}

async function removeValue(key, env) {
  try {
    await env.MAIL_KV.delete(key);
  } catch (error) {
    console.error("Pulizia KV fallita", key, String(error));
  }
}

async function enqueue(raw, from, to, env) {
  const key = `incoming/${crypto.randomUUID()}`;
  await env.MAIL_KV.put(key, raw, { expirationTtl: KV_TTL_SECONDS });
  try {
    await env.MAIL_QUEUE.send({
      key,
      from,
      to,
      receivedAt: new Date().toISOString(),
    });
  } catch (error) {
    await removeValue(key, env);
    throw error;
  }
}

async function deliverOrQueue(raw, from, to, env) {
  let result;
  try {
    result = await postToBridge(raw, from, to, env);
  } catch (error) {
    console.error("Bridge unavailable; appending to queue", String(error));
    await enqueue(raw, from, to, env);
    return "queued";
  }

  if (result.ok) {
    return "delivered";
  }
  if (isPermanentStatus(result.status)) {
    console.error("Permanent refusal", result.status, result.text);
    return "permanent";
  }

  console.error("Temporary error; appending to queue", result.status, result.text);
  await enqueue(raw, from, to, env);
  return "queued";
}

export default {
  async email(message, env) {
    if (message.rawSize > MAX_EMAIL_BYTES) {
      message.setReject("Message too large");
      return;
    }

    let raw;
    try {
      raw = await new Response(message.raw).arrayBuffer();
    } catch (error) {
      console.error("Unable to read message", String(error));
      message.setReject("Unable to read message");
      return;
    }

    try {
      const outcome = await deliverOrQueue(raw, message.from, message.to, env);
      if (outcome === "permanent") {
        message.setReject("AliasVault rejected the message");
      }
    } catch (error) {
      console.error("Impossible to deliver or append to queue", String(error));
      message.setReject("Unable to queue message");
    }
  },

  async queue(batch, env) {
    if (batch.queue === DLQ_NAME) {
      for (const item of batch.messages) {
        console.error("Retries exhausted", JSON.stringify(item.body));
        item.ack();
      }
      return;
    }

    for (const item of batch.messages) {
      const data = item.body;
      try {
        const raw = await env.MAIL_KV.get(data.key, { type: "arrayBuffer" });
        if (raw === null) {
          console.error("KV value corrupted; trying again", data.key, item.attempts);
          item.retry({ delaySeconds: 180 });
          continue;
        }

        const result = await postToBridge(raw, data.from, data.to, env);

        if (result.ok) {
          await removeValue(data.key, env);
          item.ack();
        } else if (isPermanentStatus(result.status)) {
          console.error("Permanent refusal during retry", result.status, result.text);
          await removeValue(data.key, env);
          item.ack();
        } else {
          console.error("temporary retry", item.attempts, result.status);
          item.retry({ delaySeconds: retryDelay(item.attempts) });
        }
      } catch (error) {
        console.error("Error during retry", item.attempts, String(error));
        item.retry({ delaySeconds: retryDelay(item.attempts) });
      }
    }
  },
};