import numpy as np
import os
import string
from absl import app
from absl import flags

FLAGS = flags.FLAGS

flags.DEFINE_string("user_pvc_name", None, "Name of the persistent volume claim")
flags.DEFINE_string("user_pvc_size", "512Gi", "Size of the persistent volume claim")
flags.DEFINE_string("user_pv_name", None, "Name of the persistent volume to mount", required=True)

def main(argv):
  assert len(argv) == 2
  template_file = argv[1]

  user_pvc_name = FLAGS.user_pvc_name
  if FLAGS.user_pvc_name is None:
    user_pvc_name = f"{os.environ.get('USER')}-pvc"

  with open(template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        USER_PVC_NAME=user_pvc_name,
        USER_PVC_SIZE=FLAGS.user_pvc_size,
        USER_PV_NAME=FLAGS.user_pv_name,
    )
    print(content)

if __name__ == "__main__":
  app.run(main)
