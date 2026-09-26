// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import java.time.Instant;
import java.util.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.errors.InvalidProducerEpochException;
import org.apache.kafka.common.errors.ProducerFencedException;
import org.apache.kafka.common.serialization.StringSerializer;

// Storefront server-side event publisher: checkout and cart events emitted by the
// storefront backend, published transactionally into the clickstream. A batch that
// contains an order flagged as synthetic (load-test traffic) is aborted and its real
// events are re-published in the next transaction, so test orders never reach consumers.
// A batch that fails for any other reason (a broker restart, a timeout) is re-published
// in full by a fresh producer; a producer whose epoch someone else bumped (fenced) gives up.
public class ServerEvents {
  static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }
  static volatile boolean stopping = false;

  static KafkaProducer<String, String> open() {
    Properties p = new Properties();
    p.put("bootstrap.servers", env("KAFKA_BOOTSTRAP", "kafka-kafka-bootstrap.streaming.svc:9092"));
    p.put("transactional.id", env("TRANSACTIONAL_ID", "storefront-server-events"));
    p.put("transaction.timeout.ms", env("TRANSACTION_TIMEOUT_MS", "900000"));
    p.put("key.serializer", StringSerializer.class.getName());
    p.put("value.serializer", StringSerializer.class.getName());
    KafkaProducer<String, String> producer = new KafkaProducer<>(p);
    producer.initTransactions();
    producer.beginTransaction();
    return producer;
  }

  public static void main(String[] args) throws Exception {
    long intervalMs = Long.parseLong(env("COMMIT_INTERVAL_MS", "2000"));
    int maxRecords = Integer.parseInt(env("COMMIT_MAX_RECORDS", "5000"));
    double eps = Double.parseDouble(env("EVENTS_PER_SEC", "3"));
    String topic = env("TOPIC", "events.raw");
    Thread main = Thread.currentThread();
    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
      stopping = true;
      try { main.join(25000); } catch (InterruptedException ignored) { }
    }));
    KafkaProducer<String, String> producer = open();
    String[] types = {"checkout_started", "add_to_cart", "add_to_cart", "purchase", "remove_from_cart"};
    Random r = new Random();
    long seq = Long.parseLong(env("START_SEQ", String.valueOf(System.currentTimeMillis() / 1000 * 10)));
    List<String[]> batch = new ArrayList<>();
    boolean synthetic = false;
    long opened = System.currentTimeMillis();
    long batches = 0;
    while (true) {
      try {
        long now = System.currentTimeMillis();
        boolean test = r.nextInt(400) == 0;
        String user = test ? "loadtest-" + r.nextInt(50) : "u" + r.nextInt(5000);
        String ev = String.format(
            "{\"event_id\":\"srv-%d\",\"event_type\":\"%s\",\"event_time\":\"%s\",\"user_id\":\"%s\",\"session_id\":\"ss-%s\",\"product_id\":\"%d\",\"category\":\"server\",\"quantity\":%d,\"unit_price\":%.2f,\"currency\":\"USD\",\"synthetic\":%b}",
            seq++, types[r.nextInt(types.length)], Instant.ofEpochMilli(now), user, user, 1 + r.nextInt(50), 1 + r.nextInt(3), 5 + r.nextInt(9500) / 100.0, test);
        batch.add(new String[] {user, ev});
        synthetic |= test;
        producer.send(new ProducerRecord<>(topic, user, ev));
        boolean due = now - opened >= intervalMs || batch.size() >= maxRecords || stopping;
        if (due) {
          if (synthetic) {
            producer.abortTransaction();
            producer.beginTransaction();
            int kept = 0;
            for (String[] e : batch) if (!e[1].contains("\"synthetic\":true")) { producer.send(new ProducerRecord<>(topic, e[0], e[1])); kept++; }
            producer.commitTransaction();
            System.out.println(Instant.now() + " batch " + (++batches) + ": synthetic order screened out, re-published " + kept + " of " + batch.size() + " events");
          } else {
            producer.commitTransaction();
            batches++;
            if (batches % 50 == 0 || intervalMs >= 60000) System.out.println(Instant.now() + " batch " + batches + ": committed " + batch.size() + " events");
          }
          if (stopping) { producer.close(); System.out.println(Instant.now() + " shutdown: last batch committed"); return; }
          batch.clear(); synthetic = false; opened = System.currentTimeMillis();
          producer.beginTransaction();
        }
        Thread.sleep((long) (1000 / eps));
      } catch (ProducerFencedException | InvalidProducerEpochException e) {
        // the id's epoch was bumped by someone else (a new instance, or an operator ending the
        // transaction): this process no longer owns the id and must not publish under it
        System.out.println(Instant.now() + " FENCED: another producer took over transactional id; " + batch.size() + " unpublished events dropped: " + e.getMessage());
        System.exit(2);
      } catch (KafkaException e) {
        // not fenced: a fresh producer with the same id aborts the open transaction on init;
        // re-send the whole batch in a new one (synthetic orders are screened at its commit)
        System.out.println(Instant.now() + " batch failed (" + e.getClass().getSimpleName() + "), re-publishing " + batch.size() + " events");
        try { producer.close(java.time.Duration.ofSeconds(5)); } catch (Exception ignored) { }
        while (true) {
          try {
            producer = open();
            for (String[] b : batch) producer.send(new ProducerRecord<>(topic, b[0], b[1]));
            break;
          } catch (ProducerFencedException | InvalidProducerEpochException f) {
            System.out.println(Instant.now() + " FENCED: another producer took over transactional id; " + batch.size() + " unpublished events dropped");
            System.exit(2);
          } catch (KafkaException retry) {
            Thread.sleep(5000);
          }
        }
      }
    }
  }
}
