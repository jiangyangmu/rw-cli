import numpy as np
import os
import string
from absl import app
from absl import flags

FLAGS = flags.FLAGS

flags.DEFINE_string("jobset_name", None, "Name of the jobset")
flags.DEFINE_string("tpu_type", None, "TPU type and topology (e.g., tpu7x:4x4x8)", required=True)
flags.DEFINE_integer("tpu_slices", 1, "Number of TPU slices")

flags.DEFINE_string("server_image", "us-docker.pkg.dev/cloud-tpu-v2-images/pathways/server:latest", "Pathways server image")
flags.DEFINE_string("proxy_image", "us-docker.pkg.dev/cloud-tpu-v2-images/pathways/proxy_server:latest", "Pathways proxy server image")
flags.DEFINE_string("user_container_image", None, "Image of the user container")

flags.DEFINE_string("gcs_scratch_location", "gs://cloud-pathways-staging/tmp", "GCS scratch location")

flags.DEFINE_string("user_container", None, "Name of the user container")
flags.DEFINE_string("user_pvc_name", None, "Name of the persistent volume claim to mount")
flags.DEFINE_string("user_disk_mount_path", None, "Path to mount the user disk")

# cluster specific flags
flags.DEFINE_enum(
    "bodaborg_super_alpha_cluster_priority_class",
    "scale-test",
    ["gsc", "dev", "scale-test", "ml-perf"],
    "Priority class for bodaborg-super-alpha-cluster",
)


def main(argv):
  assert len(argv) == 2
  template_file = argv[1]

  tpu_type, topology = FLAGS.tpu_type.split(':')
  num_chips = np.prod([int(d) for d in topology.split('x')])
  assert num_chips >= 4 and num_chips % 4 == 0

  jobset_name = FLAGS.jobset_name
  if FLAGS.jobset_name is None:
    jobset_name = f"{os.environ.get('USER')}-{tpu_type}-{num_chips}"

  with open(template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        JOBSET_NAME=jobset_name,
        USER=os.environ.get('USER'),
        SERVER_IMAGE=FLAGS.server_image,
        PROXY_IMAGE=FLAGS.proxy_image,
        GCS_SCRATCH_LOCATION=FLAGS.gcs_scratch_location,
        TPU_TYPE=tpu_type,
        TOPOLOGY=topology,
        REPLICAS=FLAGS.tpu_slices,
        COMPLETIONS=num_chips // 4,
        PARALLELISM=num_chips // 4,
        PODSET_SLICE_TOPOLOGY=topology if num_chips <= 64 else "4x4x4",
        PODSET_SLICE_SIZE=num_chips // 4 if num_chips <= 64 else 16,
        USER_CONTAINER=FLAGS.user_container,
        USER_CONTAINER_IMAGE=FLAGS.user_container_image,
        USER_PVC_NAME=FLAGS.user_pvc_name,
        USER_DISK_MOUNT_PATH=FLAGS.user_disk_mount_path,
        PRIORITY_CLASS=FLAGS.bodaborg_super_alpha_cluster_priority_class,
    )
    print(content)

if __name__ == "__main__":
  app.run(main)
