#!/usr/bin/env python
#
# Copyright (c) 2020 Seagate Technology LLC and/or its Affiliates
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# For any questions about this software or licensing,
# please email opensource@seagate.com or cortx-questions@seagate.com.
#

import datetime

def tq_task_common_get(elem, r):
    task = r[0]
    info = r[2]

    elem["task_id"] = task['task_id']
    elem["task_id_short"] = task['task_id'][:4] \
        + "..." + task['task_id'][-4:]

    elem["desc"] = info['info']['conf']['common'].get('description')
    elem["prio"] = info['info']['conf']['common']['priority']
    elem["user"] = info['info']['conf']['common']['user'].\
        replace("@seagate.com", "")

    elem['workload'] = info['info']['conf']['workload']

    elem['benchmark'] = info['info']['conf']['benchmark']
    elem['parameters'] = info['info']['conf']['parameter']

    fmt = '%Y-%m-%d %H:%M:%S.%f'
    hms = '%Y-%m-%d %H:%M:%S'
    q = datetime.datetime.strptime(info['info']['enqueue_time'], fmt)
    elem['time'] = {
        "enqueue": q.strftime(hms),
    }

    if 'start_time' in info['info']:
        s = datetime.datetime.strptime(info['info']['start_time'], fmt)
        elem['time']['start'] = s.strftime(hms)

    if 'finish_time' in info['info']:
        f = datetime.datetime.strptime(info['info']['finish_time'], fmt)
        elem['time']['end'] = f.strftime(hms)