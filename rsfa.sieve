### BEGIN RSFA ###
require ["editheader", "variables"];

if header :matches "x-envelope-to" "*@*.*.*"
{
  set "localpart" "${1}";
  set "subdomain" "${2}";
# add exclusion subdomains below
  if header :matches "x-envelope-to" ["*@excluded.doma.in"]
  {
    stop;
  }
  if header :matches "Subject" "*" {
      # ... to get it in a match group that can then be stored in a variable:
      set "subject" "${1}";
  }

  # We can't "replace" a header, but we can delete (all instances of) it and
  # re-add (a single instance of) it:
  deleteheader "Subject";
  # Append/prepend as you see fit
  addheader :last "Subject" "|${localpart}@${subdomain}| ${subject}";
  # Note that the header is added ":last" (so it won't appear before possible
  # "Received" headers)
}
### END RSFA ###
