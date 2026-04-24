import argparse
import math
import os
import string

_USER_DISK_VOLUMN_MOUNT = """
              - mountPath: "${USER_DISK_MOUNT_PATH}"
                name: user-disk
"""
_USER_DISK_VOLUMN = """
            - name: user-disk
              persistentVolumeClaim:
                claimName: ${USER_PVC_NAME}
"""

def main():
  parser = argparse.ArgumentParser()

  parser.add_argument("template_file", help="Path to the template file")

  parser.add_argument("--jobset_name", default=None, help="Name of the jobset")

  parser.add_argument("--tpu_type", required=True, help="TPU type and topology (e.g., tpu7x:4x4x8)")
  parser.add_argument("--tpu_slices", type=int, default=1, help="Number of TPU slices")

  parser.add_argument("--server_image", default="us-docker.pkg.dev/cloud-tpu-v2-images/pathways/server:latest", help="Pathways server image")
  parser.add_argument("--proxy_image", default="us-docker.pkg.dev/cloud-tpu-v2-images/pathways/proxy_server:latest", help="Pathways proxy server image")

  parser.add_argument("--gcs_scratch_location", default="gs://cloud-pathways-staging/tmp", help="GCS scratch location")

  parser.add_argument("--user_container", default=None, help="Name of the user container")
  parser.add_argument("--user_container_image", default=None, help="Image of the user container")
  parser.add_argument("--user_pvc_name", default=None, help="Name of the persistent volume claim to mount")
  parser.add_argument("--user_disk_mount_path", default=None, help="Path to mount the user disk")

  args = parser.parse_args()

  tpu_type, topology = args.tpu_type.split(':')
  num_chips = math.prod([int(d) for d in topology.split('x')])
  assert num_chips >= 4 and num_chips % 4 == 0

  jobset_name = args.jobset_name
  if args.jobset_name is None:
    jobset_name = f"{os.environ.get('USER')}-{tpu_type}-{num_chips}"

  if tpu_type == "tpu7x":
    slice_topology = topology if num_chips <= 64 else "4x4x4"
    slice_size = num_chips // 4 if num_chips <= 64 else 16
  elif tpu_type == "tpuv5":
    slice_topology = topology if num_chips <= 8 else "2x2x2"
    slice_size = num_chips // 4 if num_chips <= 8 else 2
  else:
    raise ValueError(f"Unsupported TPU type {tpu_type}")

  if args.user_pvc_name and args.user_disk_mount_path:
    user_disk_volumn = string.Template(_USER_DISK_VOLUMN).substitute(
      USER_PVC_NAME=args.user_pvc_name)[:-1]
    user_disk_volumn_mount = string.Template(_USER_DISK_VOLUMN_MOUNT).substitute(
      USER_DISK_MOUNT_PATH=args.user_disk_mount_path)[:-1]
  else:
    user_disk_volumn = ""
    user_disk_volumn_mount = ""

  with open(args.template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        JOBSET_NAME=jobset_name,
        USER=os.environ.get('USER'),
        SERVER_IMAGE=args.server_image,
        PROXY_IMAGE=args.proxy_image,
        GCS_SCRATCH_LOCATION=args.gcs_scratch_location,
        TPU_TYPE=tpu_type,
        TOPOLOGY=topology,
        REPLICAS=args.tpu_slices,
        COMPLETIONS=num_chips // 4,
        PARALLELISM=num_chips // 4,
        PODSET_SLICE_TOPOLOGY=slice_topology,
        PODSET_SLICE_SIZE=slice_size,
        USER_CONTAINER=args.user_container,
        USER_CONTAINER_IMAGE=args.user_container_image,
        USER_DISK_VOLUMN=user_disk_volumn,
        USER_DISK_VOLUMN_MOUNT=user_disk_volumn_mount,
    )
    print(content)

if __name__ == "__main__":
  main()
