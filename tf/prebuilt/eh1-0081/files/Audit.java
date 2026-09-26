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

import java.io.*;
import java.net.URI;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.KeyStore;
import java.security.cert.*;
import java.time.*;
import java.util.*;
import java.util.regex.*;
import javax.net.ssl.*;
import org.apache.kafka.clients.admin.*;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.common.*;
import org.apache.kafka.common.serialization.StringDeserializer;

/**
 * eh1-0081 status exporter and seed in one single-file program (run with
 * `java -cp '/opt/kafka/libs/*' Audit.java <mode>` in the Strimzi Kafka image).
 *
 * Flags published into Secret kafka-audit/clickstream-flags (strings "true"/"false"), read by
 * task.yaml with resource_property:
 *   feed_current  every poll for the last 5 minutes saw events.product-enriched within 90 s of wall
 *                 clock (newest event_time, taken from the committed events.raw copy, among server
 *                 events the exporter itself saw committed there; healthy 5-12 s, up to 600 s while either cause remains) AND
 *                 product.activity still being published: its newest 1-minute window ending within
 *                 420 s (healthy 92-273 s: windows close only when the watermark has advanced on
 *                 every enriched partition, so emission is bursty even when all is well).
 *   replay_ok     CronJob streaming/late-event-replay exists, is not suspended, keeps its seeded
 *                 schedule, last succeeded within 11 minutes, and replay runs committed at least 1000
 *                 mobile events into events.raw after the seed.
 *   data_intact   (latched) events.raw and mobile.late-events keep their topic ids and log-start
 *                 offsets; the replay group's committed position never runs ahead of the mobile
 *                 events that exist in events.raw (at once) or, once visible, of those committed
 *                 there (no skipped backlog); no non-synthetic server event whose latest copy is
 *                 behind the last stable offset is missing from the committed data; no committed
 *                 server or mobile event below the highest offset of its partition already seen in
 *                 events.product-enriched stays missing from it for 180 s (at least 20: a skip).
 *   no_leak       (latched) events.product-enriched never carries a synthetic load-test order or a
 *                 mobile event that stays uncommitted in events.raw, and the enrichment group's
 *                 committed position never runs past the last stable offset (a read_committed
 *                 consumer cannot).
 * Latched flags need a violation on two consecutive polls, judged only when every consumer has
 * caught up; a pass that cannot catch up publishes the objectives false and leaves the latches
 * alone, and after ten minutes without a complete pass the safeguards read "unknown". The latches
 * are re-read from the Secret on start (retried until readable). Nothing is published true
 * before the seed has finished. Nothing informative is logged.
 */
public class Audit {
  static final String AUDIT = "kafka-audit", STREAM = "streaming", SF = "storefront";
  static final String FLAGS = "clickstream-flags", STATE = "seed-state";
  static final String RAW = "events.raw", MOBILE = "mobile.late-events", ENRICHED = "events.product-enriched";
  static final String ACTIVITY = "product.activity";
  static final String REPLAY_GROUP = "late-event-replay";
  static final String BOOT = env("KAFKA_BOOTSTRAP", "kafka-kafka-bootstrap.streaming.svc:9092");

  static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

  public static void main(String[] a) throws Exception {
    switch (a.length == 0 ? "" : a[0]) {
      case "exporter" -> new Exporter().run();
      case "seed" -> Seed.run();
      default -> { System.err.println("usage: Audit exporter|seed"); System.exit(2); }
    }
  }

  // ---------------------------------------------------------------- Kubernetes API
  static final class K8s {
    static HttpClient client;
    static String token;
    static final String API = "https://kubernetes.default.svc";

    static synchronized HttpClient http() throws Exception {
      if (client != null) return client;
      CertificateFactory cf = CertificateFactory.getInstance("X.509");
      KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
      ks.load(null, null);
      try (InputStream in = new FileInputStream("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")) {
        int i = 0;
        for (java.security.cert.Certificate c : cf.generateCertificates(in)) ks.setCertificateEntry("ca" + i++, c);
      }
      TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
      tmf.init(ks);
      SSLContext ctx = SSLContext.getInstance("TLS");
      ctx.init(null, tmf.getTrustManagers(), null);
      client = HttpClient.newBuilder().sslContext(ctx).connectTimeout(Duration.ofSeconds(10)).build();
      return client;
    }

    static String tok() throws IOException {
      return Files.readString(Path.of("/var/run/secrets/kubernetes.io/serviceaccount/token")).trim();
    }

    static String call(String method, String path, String body, String ctype) throws Exception {
      HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(API + path)).timeout(Duration.ofSeconds(20))
          .header("Authorization", "Bearer " + tok()).header("Accept", "application/json");
      if (body == null) b.method(method, HttpRequest.BodyPublishers.noBody());
      else b.header("Content-Type", ctype).method(method, HttpRequest.BodyPublishers.ofString(body));
      HttpResponse<String> r = http().send(b.build(), HttpResponse.BodyHandlers.ofString());
      if (r.statusCode() >= 300) throw new IOException(method + " " + path + " -> " + r.statusCode());
      return r.body();
    }

    static String get(String path) throws Exception { return call("GET", path, null, null); }

    static void mergePatch(String path, String json) throws Exception {
      call("PATCH", path, json, "application/merge-patch+json");
    }

    static Map<String, String> secret(String ns, String name) throws Exception {
      String body = get("/api/v1/namespaces/" + ns + "/secrets/" + name);
      Map<String, String> out = new TreeMap<>();
      Matcher m = Pattern.compile("\"data\"\\s*:\\s*\\{([^}]*)\\}").matcher(body);
      if (!m.find()) return out;
      Matcher kv = Pattern.compile("\"([^\"]+)\"\\s*:\\s*\"([^\"]*)\"").matcher(m.group(1));
      while (kv.find()) out.put(kv.group(1), new String(Base64.getDecoder().decode(kv.group(2)), StandardCharsets.UTF_8));
      return out;
    }

    static void putSecret(String ns, String name, Map<String, String> data) throws Exception {
      StringBuilder sb = new StringBuilder("{\"stringData\":{");
      boolean first = true;
      for (Map.Entry<String, String> e : data.entrySet()) {
        if (!first) sb.append(',');
        first = false;
        sb.append(q(e.getKey())).append(':').append(q(e.getValue()));
      }
      sb.append("}}");
      mergePatch("/api/v1/namespaces/" + ns + "/secrets/" + name, sb.toString());
    }

    static String q(String s) {
      StringBuilder sb = new StringBuilder("\"");
      for (char c : s.toCharArray()) {
        if (c == '"' || c == '\\') sb.append('\\').append(c);
        else if (c == '\n') sb.append("\\n");
        else if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
        else sb.append(c);
      }
      return sb.append('"').toString();
    }

    /** First string value of "key": "..." after the given anchor in a JSON document. */
    static String field(String json, String anchor, String key) {
      int i = anchor == null ? 0 : json.indexOf(anchor);
      if (i < 0) return null;
      Matcher m = Pattern.compile("\"" + Pattern.quote(key) + "\"\\s*:\\s*(\"((?:[^\"\\\\]|\\\\.)*)\"|true|false|-?[0-9]+)").matcher(json);
      if (!m.find(i)) return null;
      return m.group(2) != null ? m.group(2) : m.group(1);
    }
  }

  // ---------------------------------------------------------------- Kafka helpers
  static Properties consumerProps(String isolation) {
    Properties p = new Properties();
    p.put("bootstrap.servers", BOOT);
    p.put("enable.auto.commit", "false");
    p.put("isolation.level", isolation);
    p.put("max.poll.records", "5000");
    p.put("key.deserializer", StringDeserializer.class.getName());
    p.put("value.deserializer", StringDeserializer.class.getName());
    p.put("client.id", "kafka-audit-" + isolation);
    return p;
  }

  static Admin admin() {
    Properties p = new Properties();
    p.put("bootstrap.servers", BOOT);
    p.put("request.timeout.ms", "20000");
    p.put("default.api.timeout.ms", "30000");
    return Admin.create(p);
  }

  static String topicId(Admin ad, String topic) throws Exception {
    return ad.describeTopics(List.of(topic)).allTopicNames().get().get(topic).topicId().toString();
  }

  static List<TopicPartition> partitions(Admin ad, String topic) throws Exception {
    List<TopicPartition> out = new ArrayList<>();
    for (TopicPartitionInfo i : ad.describeTopics(List.of(topic)).allTopicNames().get().get(topic).partitions())
      out.add(new TopicPartition(topic, i.partition()));
    return out;
  }

  static Map<TopicPartition, Long> offsets(Admin ad, List<TopicPartition> tps, OffsetSpec spec, IsolationLevel iso) throws Exception {
    Map<TopicPartition, OffsetSpec> req = new HashMap<>();
    for (TopicPartition tp : tps) req.put(tp, spec);
    Map<TopicPartition, Long> out = new TreeMap<>(Comparator.comparing(TopicPartition::toString));
    ad.listOffsets(req, new ListOffsetsOptions(iso)).all().get().forEach((k, v) -> out.put(k, v.offset()));
    return out;
  }

  static long groupPosition(Admin ad, String group, String topic) throws Exception {
    long sum = 0;
    for (Map.Entry<TopicPartition, OffsetAndMetadata> e : ad.listConsumerGroupOffsets(group).partitionsToOffsetAndMetadata().get().entrySet())
      if (e.getKey().topic().equals(topic) && e.getValue() != null) sum += e.getValue().offset();
    return sum;
  }

  static String jsonField(String json, String key) {
    Matcher m = Pattern.compile("\"" + key + "\"\\s*:\\s*(\"((?:[^\"\\\\]|\\\\.)*)\"|true|false)").matcher(json);
    if (!m.find()) return null;
    return m.group(2) != null ? m.group(2) : m.group(1);
  }

  static long isoMillis(String s) {
    try { return Instant.parse(s).toEpochMilli(); } catch (Exception e) { return -1; }
  }

  // ---------------------------------------------------------------- exporter
  static final class Exporter {
    static final String ENRICH_GROUP = "primary-flink-sql-enrich-events-raw";
    KafkaConsumer<String, String> uncommitted, committed, enriched, activity;
    int rawPartitions = -1;
    long activityNewest = -1, enrichedNewest = -1;
    // server events seen in the log (id -> partition, offset and append time of its latest copy)
    final Map<String, long[]> srvSeen = new HashMap<>();
    // committed server events: id -> event time taken from the committed events.raw copy (freshness
    // uses this time, never the enriched record's own field, so records written straight into the
    // enriched topic cannot make it look current; v1 independent analysis)
    final Map<String, Long> srvCommitted = new HashMap<>();
    final Set<String> mobileCommitted = new HashSet<>();
    final Set<String> mobileSeenAny = new HashSet<>();
    final Map<String, Integer> suspectLeak = new HashMap<>();
    final Deque<long[]> freshness = new ArrayDeque<>(); // [pollMillis, ok]
    // [pollMillis, replayed since seed, then the events.raw high-water mark per partition]
    final Deque<long[]> replayHistory = new ArrayDeque<>();
    long lastCaughtUp = System.currentTimeMillis();
    // completeness (v3): committed server and mobile events not yet seen in events.product-enriched,
    // per partition (offset -> id) with an id index (partition, offset, first read wall ms); enriched
    // ids whose raw copy was not read yet (id -> wall ms); the matched offset range per partition
    final Map<Integer, TreeMap<Long, String>> rawPending = new HashMap<>();
    final Map<String, long[]> rawPendingById = new HashMap<>();
    final Map<String, Long> enrichedUnmatched = new HashMap<>();
    final Map<Integer, long[]> matchedRange = new HashMap<>();
    // enriched server-event ids whose committed raw copy was not read yet (raw is drained first,
    // so a copy committed during the pass shows up on the next one); id -> first seen, wall ms
    final Map<String, Long> pendingEnriched = new HashMap<>();
    boolean leakOnce = false, intactOnce = false, syntheticSeen = false, aheadOnce = false;

    void rawCommitted(String id, int p, long off) {
      if (enrichedUnmatched.remove(id) != null) { matched(p, off); return; }
      long[] old = rawPendingById.put(id, new long[] {p, off, System.currentTimeMillis()});
      if (old != null && rawPending.containsKey((int) old[0])) rawPending.get((int) old[0]).remove(old[1]);
      rawPending.computeIfAbsent(p, k -> new TreeMap<>()).put(off, id);
    }

    void enrichedSeen(String id) {
      long[] s = rawPendingById.remove(id);
      if (s == null) { enrichedUnmatched.putIfAbsent(id, System.currentTimeMillis()); return; }
      rawPending.get((int) s[0]).remove(s[1]);
      matched((int) s[0], s[1]);
    }

    void matched(int p, long off) {
      long[] r = matchedRange.computeIfAbsent(p, k -> new long[] {off, off});
      r[0] = Math.min(r[0], off);
      r[1] = Math.max(r[1], off);
    }

    /** (Re)assign every consumer from the beginning, dropping what was read (partition count changed or start). */
    void assignAll(Admin ad) throws Exception {
      for (KafkaConsumer<String, String> c : Arrays.asList(uncommitted, committed, enriched, activity)) if (c != null) c.close();
      uncommitted = new KafkaConsumer<>(consumerProps("read_uncommitted"));
      committed = new KafkaConsumer<>(consumerProps("read_committed"));
      enriched = new KafkaConsumer<>(consumerProps("read_uncommitted"));
      activity = new KafkaConsumer<>(consumerProps("read_uncommitted"));
      srvSeen.clear(); srvCommitted.clear(); pendingEnriched.clear();
      rawPending.clear(); rawPendingById.clear(); enrichedUnmatched.clear(); matchedRange.clear(); mobileCommitted.clear(); mobileSeenAny.clear(); suspectLeak.clear();
      replayHistory.clear();
      enrichedNewest = -1; activityNewest = -1;
      List<TopicPartition> raw = partitions(ad, RAW);
      rawPartitions = raw.size();
      for (KafkaConsumer<String, String> c : List.of(uncommitted, committed)) { c.assign(raw); c.seekToBeginning(raw); }
      List<TopicPartition> enr = partitions(ad, ENRICHED);
      enriched.assign(enr);
      enriched.seekToBeginning(enr);
      List<TopicPartition> act = partitions(ad, ACTIVITY);
      activity.assign(act);
      activity.seekToBeginning(act);
    }

    /**
     * Reads until every assigned partition reaches the end offset seen at the start of this pass
     * (for a read_committed consumer that end is the last stable offset), within a time budget.
     * Returns whether it got there: checks that compare the consumers only run when all have.
     */
    boolean drain(KafkaConsumer<String, String> c, java.util.function.Consumer<ConsumerRecord<String, String>> f) {
      Map<TopicPartition, Long> end = c.endOffsets(c.assignment());
      long deadline = System.currentTimeMillis() + 90000;
      while (System.currentTimeMillis() < deadline) {
        boolean done = true;
        for (TopicPartition tp : c.assignment()) if (c.position(tp) < end.get(tp)) done = false;
        if (done) return true;
        for (ConsumerRecord<String, String> r : c.poll(Duration.ofMillis(500))) f.accept(r);
      }
      return false;
    }

    void run() throws Exception {
      // the latches must survive restarts: never start without having read them
      Map<String, String> prev = null;
      while (prev == null) {
        try { prev = K8s.secret(AUDIT, FLAGS); } catch (Exception e) { Thread.sleep(5000); }
      }
      // only "false" is a latched verdict; "unknown" (written while blind) is not carried over
      String dataIntact = "false".equals(prev.get("data_intact")) ? "false" : "true";
      String noLeak = "false".equals(prev.get("no_leak")) ? "false" : "true";
      Admin ad = admin();
      int errorsInRow = 0;
      while (true) {
        Map<String, String> out = new TreeMap<>();
        out.put("feed_current", "false");
        out.put("replay_ok", "false");
        Map<String, String> seed;
        try { seed = K8s.secret(AUDIT, STATE); } catch (Exception e) {
          // a failed read of seed-state is neither "unseeded" nor an empty seed: skip this poll
          // (keeping the last published flags and the blind timer running)
          Thread.sleep(20000);
          continue;
        }
        long now = System.currentTimeMillis();
        if (!"true".equals(seed.get("seeded"))) lastCaughtUp = now;
        else {
          try {
            if (rawPartitions != partitions(ad, RAW).size()) assignAll(ad);
            // the replay group's position first, then every end offset: records are appended before
            // their run commits its offsets, so everything counted here is already in the log
            long replayed = groupPosition(ad, REPLAY_GROUP, MOBILE) - Long.parseLong(seed.getOrDefault("replay_pos", "0"));
            Map<TopicPartition, OffsetAndMetadata> enrichPos = ad.listConsumerGroupOffsets(ENRICH_GROUP).partitionsToOffsetAndMetadata().get();
            Map<TopicPartition, Long> hw = offsets(ad, partitions(ad, RAW), OffsetSpec.latest(), IsolationLevel.READ_UNCOMMITTED);
            Map<TopicPartition, Long> lso = offsets(ad, partitions(ad, RAW), OffsetSpec.latest(), IsolationLevel.READ_COMMITTED);
            boolean cUp = drain(committed, r -> {
              String v = r.value();
              if (v == null) return;
              String id = jsonField(v, "event_id");
              if (id == null) return;
              if (id.startsWith("srv-")) srvCommitted.put(id, isoMillis(jsonField(v, "event_time")));
              else if (id.startsWith("m-")) mobileCommitted.add(id);
              if ((id.startsWith("srv-") || id.startsWith("m-")) && !"true".equals(jsonField(v, "synthetic")))
                rawCommitted(id, r.partition(), r.offset());
            });
            boolean uUp = drain(uncommitted, r -> {
              String v = r.value();
              if (v == null) return;
              String id = jsonField(v, "event_id");
              if (id == null) return;
              if (id.startsWith("m-")) mobileSeenAny.add(id);
              // keep the LATEST copy: a batch the publisher aborts is re-published under the same ids
              // further along the same partition, and may sit behind an open transaction for a while
              else if (id.startsWith("srv-") && !"true".equals(jsonField(v, "synthetic")))
                srvSeen.put(id, new long[] {r.partition(), r.offset(), r.timestamp()});
            });
            final boolean[] synthetic = {false};
            final long[] newest = {enrichedNewest};
            List<String> mobileEnriched = new ArrayList<>();
            boolean eUp = drain(enriched, r -> {
              String v = r.value();
              if (v == null) return;
              String user = jsonField(v, "user_id");
              String id = jsonField(v, "event_id");
              if (user != null && user.startsWith("loadtest-")) synthetic[0] = true;
              if (id == null) return;
              if (id.startsWith("srv-") || id.startsWith("m-")) enrichedSeen(id);
              if (id.startsWith("m-")) { mobileEnriched.add(id); return; }
              // freshness counts only server events the exporter has itself seen committed in
              // events.raw, so records written straight into the enriched topic do not count
              if (!id.startsWith("srv-")) return;
              Long t = srvCommitted.get(id);
              if (t == null) { pendingEnriched.putIfAbsent(id, System.currentTimeMillis()); return; }
              if (t > newest[0] && t <= System.currentTimeMillis() + 60000) newest[0] = t;
            });
            for (Iterator<Map.Entry<String, Long>> it = pendingEnriched.entrySet().iterator(); it.hasNext(); ) {
              Map.Entry<String, Long> p = it.next();
              Long t = srvCommitted.get(p.getKey());
              if (t != null) {
                if (t > newest[0] && t <= System.currentTimeMillis() + 60000) newest[0] = t;
                it.remove();
              } else if (now - p.getValue() > 300000) it.remove();
            }
            enrichedNewest = newest[0];
            final long[] aNewest = {activityNewest};
            boolean aUp = drain(activity, r -> {
              String we = r.value() == null ? null : jsonField(r.value(), "window_end");
              if (we == null) return;
              long t = isoMillis(we.replace(' ', 'T') + "Z");
              if (t > aNewest[0] && t <= System.currentTimeMillis() + 120000) aNewest[0] = t;
            });
            activityNewest = aNewest[0];
            boolean caughtUp = cUp && uUp && eUp && aUp;
            out.put("dbg_caught_up", String.valueOf(caughtUp));
            if (!caughtUp) throw new IllegalStateException("catching up");
            lastCaughtUp = now;

            // ---- no_leak
            // a synthetic order exists only inside transactions the publisher aborts: one sighting
            // is conclusive (and each record is read once), so it stays counted
            syntheticSeen |= synthetic[0];
            List<String> leakWhy = new ArrayList<>();
            if (syntheticSeen) leakWhy.add("synthetic order in events.product-enriched");
            // a mobile event in the enriched stream must be committed in events.raw; allow the
            // exporter's own read_committed consumer three polls (~60 s) to catch up with Flink
            for (String id : mobileEnriched) if (!mobileCommitted.contains(id)) suspectLeak.putIfAbsent(id, 0);
            suspectLeak.keySet().removeIf(mobileCommitted::contains);
            suspectLeak.replaceAll((k, age) -> age + 1);
            if (suspectLeak.values().stream().anyMatch(x -> x >= 3)) leakWhy.add("uncommitted mobile events in events.product-enriched");
            // a read_committed consumer can never have committed a position past the last stable
            // offset (read after its position, and the LSO never moves back)
            for (Map.Entry<TopicPartition, OffsetAndMetadata> e : enrichPos.entrySet()) {
              Long l = lso.get(e.getKey());
              if (e.getValue() != null && l != null && e.getValue().offset() > l) { leakWhy.add("enrichment position past the LSO on " + e.getKey()); break; }
            }
            boolean leak = !leakWhy.isEmpty();
            if (leak && leakOnce) noLeak = "false";
            leakOnce = leak;
            out.put("dbg_leak", leak ? String.join("; ", leakWhy) : "none");

            // ---- data_intact
            List<String> why = new ArrayList<>();
            if (!Objects.equals(topicId(ad, RAW), seed.get("raw_topic_id"))) why.add("raw topic id");
            if (!Objects.equals(topicId(ad, MOBILE), seed.get("mobile_topic_id"))) why.add("mobile topic id");
            for (String t : List.of(RAW, MOBILE)) {
              for (Map.Entry<TopicPartition, Long> e : offsets(ad, partitions(ad, t), OffsetSpec.earliest(), IsolationLevel.READ_UNCOMMITTED).entrySet()) {
                String k = "start_" + e.getKey();
                if (seed.containsKey(k) && e.getValue() > Long.parseLong(seed.get(k))) why.add("log start " + e.getKey());
              }
            }
            long mobileBase = Long.parseLong(seed.getOrDefault("mobile_committed", "0"));
            long published = mobileCommitted.size() - mobileBase;
            long existed = mobileSeenAny.size() - mobileBase;
            out.put("dbg_replayed", String.valueOf(replayed));
            out.put("dbg_published", String.valueOf(published));
            // (1) at once: the replay can only have moved events that exist in events.raw at all
            boolean ahead = replayed > existed + 200;
            // (2) exactly: once the committed reader has passed the high-water mark recorded with an
            //     earlier position, every run committed by then is visible
            long[] rec = new long[2 + rawPartitions];
            rec[0] = now; rec[1] = replayed;
            for (Map.Entry<TopicPartition, Long> e : hw.entrySet()) rec[2 + e.getKey().partition()] = e.getValue();
            replayHistory.addLast(rec);
            long[] settled = null;
            for (long[] h : replayHistory) {
              boolean passed = true;
              for (int p = 0; p < rawPartitions; p++) {
                Long pos = committed.position(new TopicPartition(RAW, p));
                if (pos == null || pos < h[2 + p]) { passed = false; break; }
              }
              if (passed) settled = h;
            }
            while (replayHistory.size() > 1 && replayHistory.peekFirst() != settled && replayHistory.peekFirst()[0] < now - 1800000) replayHistory.removeFirst();
            final long settledAt = settled == null ? -1 : settled[0];
            if (settled != null) replayHistory.removeIf(h -> h[0] < settledAt);
            ahead |= settled != null && settled[1] > published + 200;
            if (ahead && aheadOnce) why.add("replay offsets ahead of the mobile events published (backlog skipped)");
            aheadOnce = ahead;
            long lost = 0;
            StringBuilder lostSample = new StringBuilder();
            for (Map.Entry<String, long[]> e : srvSeen.entrySet()) {
              long[] s = e.getValue();
              Long pos = committed.position(new TopicPartition(RAW, (int) s[0]));
              if (pos != null && pos > s[1] && s[2] < now - 120000 && !srvCommitted.containsKey(e.getKey())) {
                if (++lost <= 3) lostSample.append(e.getKey()).append('@').append(s[0]).append('/').append(s[1]).append(' ');
              }
            }
            out.put("dbg_srv_lost", lost + " " + lostSample);
            if (lost > 0) why.add("server events aborted and never committed: " + lost);
            // (v3) completeness: Flink reads each partition in order and the LEFT JOIN emits every
            // event, so a committed event below the highest offset of its partition already seen
            // enriched, still missing three minutes after the exporter read it, was skipped (a
            // stateless restart at latest-offset, a group reset, a filter; v2 live 01M3CDXMZ)
            long skipped = 0;
            StringBuilder skipSample = new StringBuilder();
            for (Map.Entry<Integer, TreeMap<Long, String>> e : rawPending.entrySet()) {
              long[] r = matchedRange.get(e.getKey());
              if (r == null) continue;
              // events before the first one enriched predate the enrichment job: never judged
              SortedMap<Long, String> before = e.getValue().headMap(r[0]);
              for (String id : before.values()) rawPendingById.remove(id);
              before.clear();
              for (Map.Entry<Long, String> x : e.getValue().headMap(r[1]).entrySet()) {
                long[] s = rawPendingById.get(x.getValue());
                if (s != null && now - s[2] > 180000 && ++skipped <= 3)
                  skipSample.append(x.getValue()).append('@').append(e.getKey()).append('/').append(x.getKey()).append(' ');
              }
            }
            enrichedUnmatched.values().removeIf(t -> now - t > 600000);
            out.put("dbg_skipped", skipped + " " + skipSample);
            if (skipped >= 20) why.add("committed events never enriched (skipped downstream): " + skipped);
            boolean violated = !why.isEmpty();
            if (violated && intactOnce) dataIntact = "false";
            intactOnce = violated;
            out.put("dbg_intact", violated ? String.join("; ", why) : "none");

            // ---- feed_current: five minutes of polls, every one fresh
            long lag = enrichedNewest < 0 ? Long.MAX_VALUE : now - enrichedNewest;
            long aLag = activityNewest < 0 ? Long.MAX_VALUE : now - activityNewest;
            out.put("dbg_lag_s", lag == Long.MAX_VALUE ? "none" : String.valueOf(lag / 1000));
            out.put("dbg_activity_lag_s", aLag == Long.MAX_VALUE ? "none" : String.valueOf(aLag / 1000));
            freshness.addLast(new long[] {now, (lag <= 90000 && aLag <= 420000) ? 1 : 0});
            while (!freshness.isEmpty() && freshness.peekFirst()[0] < now - 300000) freshness.removeFirst();
            boolean allFresh = freshness.stream().allMatch(x -> x[1] == 1);
            boolean fullWindow = !freshness.isEmpty() && freshness.peekFirst()[0] <= now - 280000;
            out.put("feed_current", (allFresh && fullWindow) ? "true" : "false");

            // ---- replay_ok
            String cj = K8s.get("/apis/batch/v1/namespaces/" + STREAM + "/cronjobs/late-event-replay");
            boolean suspended = "true".equals(K8s.field(cj, "\"spec\"", "suspend"));
            String schedule = K8s.field(cj, "\"spec\"", "schedule");
            String lastOk = K8s.field(cj, "\"status\"", "lastSuccessfulTime");
            long okAge = lastOk == null ? Long.MAX_VALUE : now - isoMillis(lastOk);
            boolean replayOk = !suspended && Objects.equals(schedule, seed.get("replay_schedule"))
                && okAge <= 660000 && published >= 1000;
            out.put("dbg_replay", "suspended=" + suspended + " schedule=" + schedule + " ok_age_s=" + (okAge == Long.MAX_VALUE ? "none" : okAge / 1000));
            out.put("replay_ok", replayOk ? "true" : "false");
            errorsInRow = 0;
            out.put("dbg_err", "none");
          } catch (Exception e) {
            // a client that keeps failing (e.g. stale coordinator lookups after a broker restart,
            // measured) is replaced, and everything is read again from the start
            if (!(e instanceof IllegalStateException) && ++errorsInRow >= 3) {
              try { ad.close(Duration.ofSeconds(5)); } catch (Exception ignored) { }
              ad = admin();
              rawPartitions = -1;
              errorsInRow = 0;
            }
            String msg = e.getClass().getSimpleName() + ": " + e.getMessage();
            out.put("dbg_err", msg.substring(0, Math.min(200, msg.length())));
            out.put("feed_current", "false");
            out.put("replay_ok", "false");
          }
        }
        // an exporter that cannot finish a pass for ten minutes stops vouching for the safeguards
        boolean blind = now - lastCaughtUp > 600000;
        out.put("data_intact", blind ? "unknown" : dataIntact);
        out.put("no_leak", blind ? "unknown" : noLeak);
        out.put("published_at", String.valueOf(now / 1000));
        try {
          K8s.putSecret(AUDIT, FLAGS, out);
          Files.writeString(Path.of("/tmp/heartbeat"), String.valueOf(now / 1000));
        } catch (Exception ignored) { }
        Thread.sleep(20000);
      }
    }
  }

  // ---------------------------------------------------------------- seed
  static void say(String s) { System.out.println(Instant.now() + " step " + s); }

  // The seed's edits carry the field managers a person's kubectl would leave (kubectl-edit,
  // kubectl-rollout), so managedFields do not point at an automation (pre-live review).
  static void patchCm(String ns, String name, String dataJson) throws Exception {
    K8s.mergePatch("/api/v1/namespaces/" + ns + "/configmaps/" + name + "?fieldManager=kubectl-edit", "{\"data\":" + dataJson + "}");
  }

  static void restartDeploy(String ns, String name) throws Exception {
    K8s.call("PATCH", "/apis/apps/v1/namespaces/" + ns + "/deployments/" + name + "?fieldManager=kubectl-rollout",
        "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"" + Instant.now() + "\"}}}}}",
        "application/strategic-merge-patch+json");
  }

  static final class Seed {
    static void run() throws Exception {
      try (Admin ad = admin()) {
        say("1");
        // healthy baseline: wait for enriched output and one successful replay run
        waitFor(() -> K8s.field(K8s.get("/apis/batch/v1/namespaces/" + STREAM + "/cronjobs/late-event-replay"), "\"status\"", "lastSuccessfulTime") != null, 1500);
        say("2");
        Map<String, String> st = new TreeMap<>();
        st.put("raw_topic_id", topicId(ad, RAW));
        st.put("mobile_topic_id", topicId(ad, MOBILE));
        for (String t : List.of(RAW, MOBILE))
          for (Map.Entry<TopicPartition, Long> e : offsets(ad, partitions(ad, t), OffsetSpec.earliest(), IsolationLevel.READ_UNCOMMITTED).entrySet())
            st.put("start_" + e.getKey(), String.valueOf(e.getValue()));
        st.put("replay_schedule", K8s.field(K8s.get("/apis/batch/v1/namespaces/" + STREAM + "/cronjobs/late-event-replay"), "\"spec\"", "schedule"));
        // count mobile events already committed and the replay group's position at this moment
        long mobile = countCommittedMobile();
        st.put("mobile_committed", String.valueOf(mobile));
        st.put("replay_pos", String.valueOf(groupPosition(ad, REPLAY_GROUP, MOBILE)));
        say("3");
        // CHG-6231 happened yesterday; the iOS 7.4 release flush lands in the outbox this morning
        flushBacklog(Integer.parseInt(env("FLUSH_EVENTS", "150000")));
        say("4");
        // CHG-6240: fewer, larger server-events transactions
        patchCm(SF, "server-events", "{\"COMMIT_INTERVAL_MS\":\"600000\"}");
        restartDeploy(SF, "server-events");
        writeChangeLogs(System.currentTimeMillis());
        say("5");
        // wait for the fault to show: a dead replay run's transaction open for over two minutes
        waitFor(() -> {
          for (TransactionListing t : ad.listTransactions().all().get()) {
            if (!t.transactionalId().startsWith("late-event-replay-") || t.state() != TransactionState.ONGOING) continue;
            TransactionDescription d = ad.describeTransactions(List.of(t.transactionalId())).all().get().get(t.transactionalId());
            if (d.transactionStartTimeMs().isPresent() && System.currentTimeMillis() - d.transactionStartTimeMs().getAsLong() > 120000) return true;
          }
          return false;
        }, 1800);
        say("6");
        st.put("seeded", "true");
        st.put("seeded_at", String.valueOf(System.currentTimeMillis() / 1000));
        K8s.putSecret(AUDIT, STATE, st);
        say("7");
      }
    }

    static String at(long ms) {
      return java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm").withZone(ZoneOffset.UTC).format(Instant.ofEpochMilli(ms));
    }

    /** The two teams' change logs, dated relative to this run (CHG-6240 is the rollout just applied). */
    static void writeChangeLogs(long now) throws Exception {
      long h = 3600000L, d = 24 * h;
      String streaming = "# streaming change log (newest first)\n\n"
          + "## CHG-6231  " + at(now - 15 * h) + "  mobile-platform  late-event-replay: drain the iOS 7.4 outbox faster\n"
          + "The iOS 7.4 release left ~80k buffered events in mobile.late-events. Raised\n"
          + "REPLAY_MAX_EVENTS 20000 -> 400000 in ConfigMap streaming/late-event-replay so one run\n"
          + "drains the backlog instead of trickling it over hours. Replay runs are transactional:\n"
          + "a failed run publishes nothing and the next run simply retries it. No other change.\n\n"
          + "## CHG-6202  " + at(now - 8 * d) + "  mobile-platform  late-event-replay: longer transaction timeout\n"
          + "Large runs were being fenced by the transaction coordinator before they finished.\n"
          + "TRANSACTION_TIMEOUT_MS 60000 -> 900000 (the broker maximum).\n\n"
          + "## CHG-6180  " + at(now - 13 * d) + "  data-platform  product.activity exactly-once rollout\n"
          + "enrichment-events now reads events.raw read_committed and publishes\n"
          + "events.product-enriched / product.activity from checkpointed state.\n\n"
          + "## CHG-6114  " + at(now - 22 * d) + "  data-platform  events.raw retention\n"
          + "events.raw retention 1h (retention.ms=3600000); raw history is archived by the core job.\n";
      String storefront = "# storefront change log (newest first)\n\n"
          + "## CHG-6240  " + at(now) + "  storefront-backend  server-events: fewer, larger transactions\n"
          + "The server-events publisher committed a transaction every 2 s, writing ~43k\n"
          + "transaction markers a day into events.raw. COMMIT_INTERVAL_MS 2000 -> 600000 in\n"
          + "ConfigMap storefront/server-events (COMMIT_MAX_RECORDS stays 5000). Consumers still\n"
          + "see whole batches, so no consumer impact is expected. Rolled with kubectl rollout restart.\n\n"
          + "## CHG-6197  " + at(now - 9 * d) + "  storefront-backend  synthetic-order screening\n"
          + "Batches containing load-test orders are aborted and re-published without them, so\n"
          + "test orders never reach the clickstream.\n";
      patchCm(STREAM, "streaming-changes", "{\"changes.md\":" + K8s.q(streaming) + "}");
      patchCm(SF, "storefront-changes", "{\"changes.md\":" + K8s.q(storefront) + "}");
    }

    static void flushBacklog(int n) throws Exception {
      Properties p = new Properties();
      p.put("bootstrap.servers", BOOT);
      p.put("linger.ms", "50");
      p.put("key.serializer", org.apache.kafka.common.serialization.StringSerializer.class.getName());
      p.put("value.serializer", org.apache.kafka.common.serialization.StringSerializer.class.getName());
      String[] types = {"page_view", "page_view", "page_view", "add_to_cart", "search"};
      Random r = new Random();
      long now = System.currentTimeMillis();
      try (org.apache.kafka.clients.producer.KafkaProducer<String, String> pr = new org.apache.kafka.clients.producer.KafkaProducer<>(p)) {
        for (int i = 0; i < n; i++) {
          String user = "m" + r.nextInt(20000);
          String ev = String.format(
              "{\"event_id\":\"m-%s\",\"event_type\":\"%s\",\"event_time\":\"%s\",\"user_id\":\"%s\",\"session_id\":\"ms-%s-%d\",\"product_id\":\"%d\",\"category\":\"mobile\",\"quantity\":1,\"unit_price\":%.2f,\"currency\":\"USD\",\"client\":\"ios-7.4\"}",
              UUID.randomUUID(), types[r.nextInt(types.length)], Instant.ofEpochMilli(now - 3600000L - r.nextInt(36000000)),
              user, user, i / 40, 1 + r.nextInt(50), 5 + r.nextInt(9500) / 100.0);
          pr.send(new org.apache.kafka.clients.producer.ProducerRecord<>(MOBILE, user, ev));
        }
        pr.flush();
      }
    }

    static long countCommittedMobile() {
      try (KafkaConsumer<String, String> c = new KafkaConsumer<>(consumerProps("read_committed"))) {
        List<TopicPartition> tps = new ArrayList<>();
        for (PartitionInfo p : c.partitionsFor(RAW)) tps.add(new TopicPartition(RAW, p.partition()));
        c.assign(tps);
        c.seekToBeginning(tps);
        // events.raw never goes quiet: read up to the end (the LSO, read_committed) seen now
        Map<TopicPartition, Long> end = c.endOffsets(tps);
        Set<String> ids = new HashSet<>();
        int empty = 0;
        while (empty < 10) {
          boolean done = true;
          for (TopicPartition tp : tps) if (c.position(tp) < end.get(tp)) done = false;
          if (done) break;
          ConsumerRecords<String, String> rs = c.poll(Duration.ofSeconds(2));
          if (rs.isEmpty()) { empty++; continue; }
          empty = 0;
          for (ConsumerRecord<String, String> r : rs) {
            String id = r.value() == null ? null : jsonField(r.value(), "event_id");
            if (id != null && id.startsWith("m-")) ids.add(id);
          }
        }
        return ids.size();
      }
    }
  }

  interface Check { boolean ok() throws Exception; }

  static void waitFor(Check c, int seconds) throws Exception {
    long end = System.currentTimeMillis() + seconds * 1000L;
    while (System.currentTimeMillis() < end) {
      try { if (c.ok()) return; } catch (Exception ignored) { }
      Thread.sleep(10000);
    }
    throw new IllegalStateException("timed out");
  }

}
