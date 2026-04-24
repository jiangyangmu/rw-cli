import argparse
import os
import string

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("template_file", help="Path to the template file")
  parser.add_argument("--user_pv_name", default=None, help="Name of the persistent volume")
  parser.add_argument("--user_pv_handle", required=True, help="Handle for the persistent volume (e.g. GCS bucket name)")
  parser.add_argument("--user_pv_size", default="512Gi", help="Size of the persistent volume")
  args = parser.parse_args()

  user_pv_name = args.user_pv_name
  if args.user_pv_name is None:
    user_pv_name = f"{os.environ.get('USER')}-pv"

  with open(args.template_file, "r") as f:
    template = string.Template(f.read())
    content = template.substitute(
        USER_PV_NAME=user_pv_name,
        USER_PV_HANDLE=args.user_pv_handle,
        USER_PV_SIZE=args.user_pv_size,
    )
    print(content)

if __name__ == "__main__":
  main()
