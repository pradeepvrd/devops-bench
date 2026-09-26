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

import java.time.Duration;
import java.time.Instant;
import java.util.*;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

// Late-event replay: moves buffered mobile events from mobile.late-events into the
// clickstream topic. Each run is one Kafka transaction (records + source offsets), so a
// run is either fully visible downstream or not at all. A manifest of the run is logged
// at commit for the mobile team's reconciliation.
public class Replay {
  static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

  public static void main(String[] args) throws Exception {
    String run = env("HOSTNAME", "local");
    int maxEvents = Integer.parseInt(env("REPLAY_MAX_EVENTS", "20000"));
    String bootstrap = env("KAFKA_BOOTSTRAP", "kafka-kafka-bootstrap.streaming.svc:9092");
    String source = env("SOURCE_TOPIC", "mobile.late-events");
    String target = env("TARGET_TOPIC", "events.raw");
    String group = env("GROUP_ID", "late-event-replay");

    Properties c = new Properties();
    c.put("bootstrap.servers", bootstrap);
    c.put("group.id", group);
    c.put("enable.auto.commit", "false");
    c.put("auto.offset.reset", "earliest");
    c.put("isolation.level", "read_committed");
    c.put("max.poll.records", "2000");
    c.put("key.deserializer", StringDeserializer.class.getName());
    c.put("value.deserializer", StringDeserializer.class.getName());
    Properties p = new Properties();
    p.put("bootstrap.servers", bootstrap);
    p.put("transactional.id", env("TRANSACTIONAL_ID_PREFIX", "late-event-replay-") + run);
    p.put("transaction.timeout.ms", env("TRANSACTION_TIMEOUT_MS", "60000"));
    p.put("key.serializer", StringSerializer.class.getName());
    p.put("value.serializer", StringSerializer.class.getName());

    try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(c);
         KafkaProducer<String, String> producer = new KafkaProducer<>(p)) {
      consumer.subscribe(List.of(source));
      producer.initTransactions();
      producer.beginTransaction();
      List<String> manifest = new ArrayList<>();
      Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
      int empty = 0;
      long joinDeadline = System.currentTimeMillis() + 120000;
      while (consumer.assignment().isEmpty() && System.currentTimeMillis() < joinDeadline) consumer.poll(Duration.ofSeconds(1));
      // the polls above may already have fetched records: start again from the committed offsets
      Map<TopicPartition, OffsetAndMetadata> start = consumer.committed(consumer.assignment());
      for (TopicPartition tp : consumer.assignment()) {
        OffsetAndMetadata o = start.get(tp);
        if (o != null) consumer.seek(tp, o.offset()); else consumer.seekToBeginning(List.of(tp));
      }
      // A run drains what was buffered when it started (up to REPLAY_MAX_EVENTS); events that
      // arrive while it runs wait for the next run.
      Map<TopicPartition, Long> end = consumer.endOffsets(consumer.assignment());
      while (manifest.size() < maxEvents && empty < 5) {
        boolean drained = true;
        for (TopicPartition tp : consumer.assignment()) if (consumer.position(tp) < end.getOrDefault(tp, 0L)) drained = false;
        if (drained) break;
        ConsumerRecords<String, String> recs = consumer.poll(Duration.ofSeconds(3));
        if (recs.isEmpty()) { empty++; continue; }
        empty = 0;
        for (ConsumerRecord<String, String> r : recs) {
          if (r.offset() >= end.getOrDefault(new TopicPartition(r.topic(), r.partition()), Long.MAX_VALUE)) continue;
          producer.send(new ProducerRecord<>(target, r.key(), r.value()));
          manifest.add(String.format("%s-%d@%d %s %s", r.topic(), r.partition(), r.offset(), r.value(), HexFormat.of().formatHex(r.value().getBytes())));
          offsets.put(new TopicPartition(r.topic(), r.partition()), new OffsetAndMetadata(r.offset() + 1));
          if (manifest.size() >= maxEvents) break;
        }
        if (manifest.size() % 20000 < 2000) System.out.println(Instant.now() + " replay " + run + ": " + manifest.size() + " events staged");
      }
      if (manifest.isEmpty()) { producer.abortTransaction(); System.out.println(Instant.now() + " replay " + run + ": nothing to replay"); return; }
      producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
      producer.commitTransaction();
      System.out.println(Instant.now() + " replay " + run + ": committed " + manifest.size() + " events, manifest checksum "
          + Integer.toHexString(String.join("\n", manifest).hashCode()));
    }
  }
}
