## etcd restore commands

```bash
etcdutl snapshot restore gravity-snapshot.db \
   --name etcd-0 \
   --initial-cluster etcd-0=http://etcd-0.etcd-headless:2380,etcd-1=http://etcd-1.etcd-headless:2380,etcd-2=http://etcd-2.etcd-headless:2380 \
   --initial-advertise-peer-urls http://etcd-0.etcd-headless:2380 \
   --initial-cluster-token etcd-cluster \
   --data-dir=/var/run/etcd/default.etcd

etcdutl snapshot restore gravity-snapshot.db \
   --name etcd-1 \
   --initial-cluster etcd-0=http://etcd-0.etcd-headless:2380,etcd-1=http://etcd-1.etcd-headless:2380,etcd-2=http://etcd-2.etcd-headless:2380 \
   --initial-advertise-peer-urls http://etcd-1.etcd-headless:2380 \
   --initial-cluster-token etcd-cluster \
   --data-dir=/var/run/etcd/default.etcd

etcdutl snapshot restore gravity-snapshot.db \
   --name etcd-2 \
   --initial-cluster etcd-0=http://etcd-0.etcd-headless:2380,etcd-1=http://etcd-1.etcd-headless:2380,etcd-2=http://etcd-2.etcd-headless:2380 \
   --initial-advertise-peer-urls http://etcd-2.etcd-headless:2380 \
   --initial-cluster-token etcd-cluster \
   --data-dir=/var/run/etcd/default.etcd
```
