import os
from ngshare_exchange import configureExchange

# to prevent error message outside z2jh in docker standalone
if os.getenv("USER") is None:
    os.environ['USER'] = 'jovyan'

c=get_config()
configureExchange(c, 'http://ngshare.jhub.svc.cluster.local:8080/services/ngshare')
# Add the following line to let students access courses without configuration
# For more information, read Notes for Instructors in the documentation
c.CourseDirectory.course_id = '*'