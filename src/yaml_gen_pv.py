import numpy as np
import os
import string
from absl import app
from absl import flags

FLAGS = flags.FLAGS

flags.DEFINE_string("user_pv_name", None, "Name of the persistent volume")
flags.DEFINE_string("user_pv_handle", None, "Handle for the persistent volume (e.g. GCS bucket name)", required=True)
flags.DEFINE_string("user_pv_size", "512Gi", "Size of the persistent volume")

def main(argv):
  assert len(argv) == 2
  template_file = argv[1]

  user_pv_name = FLAGS.user_pv_name
  if FLAGS.user_pv_name is None:
    user_pv_name = f"{os.environ.get('USER')}-pv"

  with open(template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        USER_PV_NAME=user_pv_name,
        USER_PV_HANDLE=FLAGS.user_pv_handle,
        USER_PV_SIZE=FLAGS.user_pv_size,
    )
    print(content)

if __name__ == "__main__":
  app.run(main)
