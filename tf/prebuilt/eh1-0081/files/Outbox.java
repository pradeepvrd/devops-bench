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
import org.apache.kafka.common.serialization.StringSerializer;

// Mobile outbox relay: forwards events that mobile clients buffered while offline.
// They arrive minutes late and wait in mobile.late-events for the replay job.
public class Outbox {
  static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

  public static void main(String[] args) throws Exception {
    Properties p = new Properties();
    p.put("bootstrap.servers", env("KAFKA_BOOTSTRAP", "kafka-kafka-bootstrap.streaming.svc:9092"));
    p.put("key.serializer", StringSerializer.class.getName());
    p.put("value.serializer", StringSerializer.class.getName());
    p.put("linger.ms", "50");
    String topic = env("TOPIC", "mobile.late-events");
    double eps = Double.parseDouble(env("EVENTS_PER_SEC", "3"));
    long burst = Long.parseLong(env("BURST", "0"));
    String[] types = {"page_view", "page_view", "page_view", "add_to_cart", "search"};
    Random r = new Random();
    try (KafkaProducer<String, String> producer = new KafkaProducer<>(p)) {
      long sent = 0;
      while (true) {
        long now = System.currentTimeMillis();
        String user = "m" + r.nextInt(20000);
        String ev = String.format(
            "{\"event_id\":\"m-%s\",\"event_type\":\"%s\",\"event_time\":\"%s\",\"user_id\":\"%s\",\"session_id\":\"ms-%s-%d\",\"product_id\":\"%d\",\"category\":\"mobile\",\"quantity\":1,\"unit_price\":%.2f,\"currency\":\"USD\",\"client\":\"ios-7.4\"}",
            UUID.randomUUID(), types[r.nextInt(types.length)], Instant.ofEpochMilli(now - 120000 - r.nextInt(1080000)),
            user, user, now / 1800000, 1 + r.nextInt(50), 5 + r.nextInt(9500) / 100.0);
        producer.send(new ProducerRecord<>(topic, user, ev));
        sent++;
        if (burst > 0) { if (sent >= burst) break; continue; }
        if (sent % 1000 == 0) System.out.println(Instant.now() + " outbox forwarded=" + sent);
        Thread.sleep((long) (1000 / eps));
      }
      producer.flush();
      System.out.println(Instant.now() + " outbox forwarded=" + sent);
    }
  }
}
