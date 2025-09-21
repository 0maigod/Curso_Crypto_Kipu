///SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
/**
    *@title Contrato ToDoList
    *@notice Contrato para organizar tareas
    *@author i3arba - 77 Innovation Labs
*/
contract ToDoList {
    ///@notice Estructura para almacenar información de tareas
    struct Tarea {
        string descripcion;
        uint256 tiempoDeCreacion;
    }

    ///@notice Array para almacenar la estructura de datos
    Tarea[] public s_tareas;

    ///@notice Evento emitido cuando se añade una nueva tarea
    event ToDoList_TareaAnhadida(Tarea tarea);
    ///@notice Evento emitido cuando una tarea es completada y eliminada
    event ToDoList_TareaCompletadaYEliminada(string _descripcion);

    /**
        *@notice Función para añadir tareas al almacenamiento del contrato
        *@param _descripcion La descripción de la tarea que se está añadiendo
    */
    function setTarea(string memory _descripcion) external {
        Tarea memory tarea = Tarea ({
            descripcion: _descripcion,
            tiempoDeCreacion: block.timestamp
        });

        s_tareas.push(tarea);

        emit ToDoList_TareaAnhadida(tarea);
    }

    /**
        *@notice Función para eliminar tareas completadas
        *@param _descripcion Descripción de la tarea que será eliminada
    */
    function eliminarTarea(string memory _descripcion) external {
        uint256 tamanho = s_tareas.length;

        // declaración aquí
        for(uint256 i = 0; i < tamanho; ++i){
            if(keccak256(abi.encodePacked(_descripcion)) == keccak256(abi.encodePacked(s_tareas[i].descripcion))){
                // bytes32 => bytes => string

                s_tareas[i] = s_tareas[tamanho - 1];
                s_tareas.pop();

                emit ToDoList_TareaCompletadaYEliminada(_descripcion);
                return;
            }
        }
    }

    /**
        *@notice Función que retorna todas las tareas almacenadas en el array s_tareas
        *@return tarea_ Array de tareas
    */
    function getTarea() external view returns(Tarea[] memory tarea_){
        tarea_ = s_tareas;
    }
}