# SQLite workload: schema, bulk insert, indexed and range queries, joins,
# full-text-ish LIKE and JSON functions — the shapes an agent's queries use.
python3 - <<'PY' > /dev/null
import json, random, sqlite3

db = sqlite3.connect(":memory:")
db.execute("create table t(id integer primary key, name text, grp int, score real, meta text)")
db.execute("create table g(id integer primary key, label text)")
db.executemany("insert into g values (?, ?)", [(i, f"group-{i}") for i in range(200)])
rows = [(i, f"user-{i}", i % 200, random.random() * 100, json.dumps({"i": i})) for i in range(50000)]
db.executemany("insert into t values (?, ?, ?, ?, ?)", rows)
db.execute("create index t_grp on t(grp)")
db.commit()

for _ in range(40):
    db.execute("select count(*), avg(score) from t where grp between 10 and 60").fetchone()
    db.execute("select g.label, count(*), sum(t.score) from t join g on g.id = t.grp group by g.id order by 3 desc limit 5").fetchall()
    db.execute("select * from t where name like 'user-123%' order by id desc limit 20").fetchall()
    db.execute("select json_extract(meta, '$.i') from t where id < 5000").fetchall()
    db.execute("select grp, max(score) from t group by grp having max(score) > 99").fetchall()
    db.execute("update t set score = score + 0.5 where grp = 7").fetchall()
    db.commit()
PY
