import argparse
import os
import string

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("template_file", help="Path to the template file")
  parser.add_argument("--user_pvc_name", default=None, help="Name of the persistent volume claim")
  parser.add_argument("--user_pvc_size", default="512Gi", help="Size of the persistent volume claim")
  parser.add_argument("--user_pv_name", required=True, help="Name of the persistent volume to mount")
  args = parser.parse_args()

  user_pvc_name = args.user_pvc_name
  if args.user_pvc_name is None:
    user_pvc_name = f"{os.environ.get('USER')}-pvc"

  with open(args.template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        USER_PVC_NAME=user_pvc_name,
        USER_PVC_SIZE=args.user_pvc_size,
        USER_PV_NAME=args.user_pv_name,
    )
    print(content)

if __name__ == "__main__":
  main()
