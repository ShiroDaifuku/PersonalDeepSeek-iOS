"""Execute the actual migration/admission/CAS SQL with stdlib SQLite; no deployed DB."""
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ChatJobSQLTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript((ROOT / "migrations/0001_initial.sql").read_text(encoding="utf-8"))
        self.db.executescript((ROOT / "migrations/0002_cloud_knowledge.sql").read_text(encoding="utf-8"))
        self.db.execute("INSERT INTO tasks(id,user_id,title,kind,schedule_json,prompt,tools_json,notify,enabled,created_at,updated_at) VALUES('existing','owner','unchanged','one_off','{}','original','[]',0,1,'old','old')")
        self.db.executescript((ROOT / "migrations/0003_chat_jobs.sql").read_text(encoding="utf-8"))
        source = (ROOT / "src/chat-jobs.ts").read_text(encoding="utf-8")
        self.admission = re.search(r"`(INSERT OR IGNORE INTO chat_jobs[\s\S]+?)`", source).group(1)
        self.claim = re.search(r'"(UPDATE chat_jobs SET status=\'running\'[^"\n]+)"', source).group(1)
        self.finish = re.search(r'"(UPDATE chat_jobs SET status=\'succeeded\'[^"\n]+)"', source).group(1)
        self.expire = re.search(r'"(UPDATE chat_jobs SET status=\'failed\',content=\'\'[^"\n]+)"', source).group(1)

    def tearDown(self):
        self.db.close()

    def insert(self, job, owner="owner", fingerprint="frozen"):
        return self.db.execute(self.admission, [owner,job,"conv","u-"+job,job,fingerprint,"{}",1000,1000,100000,owner,0,owner]).rowcount

    def test_additive_migration_preserves_old_tasks(self):
        self.assertEqual(self.db.execute("SELECT title,prompt FROM tasks WHERE id='existing'").fetchone(), ("unchanged", "original"))

    def test_atomic_pending_limit_and_duplicate_id_do_not_overwrite(self):
        self.assertEqual(self.insert("a"), 1)
        self.assertEqual(self.insert("b"), 1)
        self.assertEqual(self.insert("c"), 0)
        self.assertEqual(self.insert("a", fingerprint="changed"), 0)
        self.assertEqual(self.db.execute("SELECT request_hash FROM chat_jobs WHERE id='a'").fetchone()[0], "frozen")
        self.db.execute("UPDATE chat_jobs SET status='cancelled' WHERE id='a'")
        self.assertEqual(self.insert("c"), 1)

    def test_claim_once_and_cancelled_result_cannot_be_overwritten(self):
        self.insert("a")
        self.assertEqual(self.db.execute(self.claim,[2000,2000,"owner","a",2000,-898000]).rowcount,1)
        self.assertEqual(self.db.execute(self.claim,[2000,2000,"owner","a",2000,-898000]).rowcount,0)
        self.db.execute("UPDATE chat_jobs SET status='cancelled' WHERE id='a'")
        self.assertEqual(self.db.execute(self.finish,["late answer","reasoning","{}",3000,"owner","a"]).rowcount,0)
        self.assertEqual(self.db.execute("SELECT status FROM chat_jobs WHERE id='a'").fetchone()[0], "cancelled")

    def test_owner_partition_and_daily_limit(self):
        for index in range(24):
            self.assertEqual(self.insert(str(index)),1)
            self.db.execute("UPDATE chat_jobs SET status='succeeded' WHERE id=?",[str(index)])
        self.assertEqual(self.insert("over-quota"),0)
        self.assertEqual(self.insert("0",owner="other-owner"),1)

    def test_expiry_erases_prompt_and_output_but_keeps_anti_replay_identity(self):
        self.insert("a")
        self.db.execute("UPDATE chat_jobs SET status='succeeded',content='private result',reasoning='private reasoning',usage_json='{}' WHERE id='a'")
        self.db.execute(self.expire, [200000])
        row = self.db.execute("SELECT content,reasoning,request_json,usage_json,error_code,request_hash FROM chat_jobs WHERE id='a'").fetchone()
        self.assertEqual(row, ("", "", None, None, "chat_expired", "frozen"))
        self.assertEqual(self.insert("a"), 0)

    def test_late_queue_delivery_cannot_start_a_new_provider_request(self):
        self.insert("a")
        self.db.execute("UPDATE chat_jobs SET expires_at=9999999 WHERE id='a'")
        self.assertEqual(self.db.execute(self.claim,[1000000,1000000,"owner","a",1000000,100000]).rowcount,0)


if __name__ == "__main__":
    unittest.main()
